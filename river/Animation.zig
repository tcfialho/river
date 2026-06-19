// SPDX-License-Identifier: GPL-3.0-only
//
// MainDeck window animations — local tween engine.
//
// The window manager (maindeck-wm) only sends absolute geometry targets via the
// render sequence. Rather than snapping to those targets, the compositor
// interpolates toward them locally inside the output frame loop, so there is no
// per-frame Wayland round-trip. Animation state lives inline on each Window
// (`anim: ?Animation`); `null` in steady state means zero idle cost.
//
// Step 1 scope: position lerp + opacity fade, fixed size, linear/simple easing.
// Texture-scale (size tween), per-tick border resize, and spring easing are
// Step 2; arbitrary cubic-bezier timing is deliberately not implemented yet.

const Animation = @This();

const std = @import("std");
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

/// What kind of transition this is — selects easing and (later) effect.
pub const Kind = enum {
    /// Window moved between layout slots: interpolate position only.
    move,
    /// Window mapped: fade in (opacity 0 -> 1). Position is fixed at map.
    open,
    /// Window closing: fade out (opacity 1 -> 0) on the detached saved tree.
    close,
};

pub const Easing = enum {
    linear,
    ease_out,
    ease_in,

    /// Map normalized time t in [0,1] to eased progress in [0,1].
    fn apply(easing: Easing, t: f32) f32 {
        return switch (easing) {
            .linear => t,
            // Quadratic ease-out: fast start, gentle stop.
            .ease_out => 1.0 - (1.0 - t) * (1.0 - t),
            // Quadratic ease-in: gentle start, fast stop.
            .ease_in => t * t,
        };
    }
};

kind: Kind,
easing: Easing,

/// Monotonic start time and total duration, in nanoseconds.
start_ns: i64,
duration_ns: i64,

/// Position endpoints (logical coordinates, top-left of the window box).
start_x: f32,
start_y: f32,
target_x: f32,
target_y: f32,

/// Last interpolated position actually applied to the scene node. Used as the
/// start point when a new target arrives mid-animation, so re-targeting does
/// not jump to the stale `box` value (which already holds the previous target).
last_x: f32,
last_y: f32,

/// Opacity endpoints, in [0,1].
start_opacity: f32,
target_opacity: f32,
last_opacity: f32,

/// Scale endpoints (1.0 = natural size). Applied around the window center via
/// SceneBuffer.setDestSize; 1.0 -> 1.0 means "no scale" (pure move). The pop on
/// open (0.65 -> 1) / close (1 -> 0.65) lives here.
start_scale: f32,
target_scale: f32,
last_scale: f32,

/// Fold a monotonic timespec into nanoseconds for trivial subtraction.
pub fn nowNs() i64 {
    const ts = util.timestamp();
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// Arm a position tween from `cur` toward `target`. If an animation is already
/// in flight, start from the last applied position (not `cur`), so a new layout
/// arriving mid-tween continues smoothly instead of jumping.
///
/// A move that interrupts an in-flight fade must NOT freeze the fade: it carries
/// the existing animation's real opacity target (e.g. 1.0 for an open fade) and
/// continues from the current opacity, so the fade still completes during/after
/// the move. (Opacity is advanced whenever start != target, not gated on kind.)
pub fn armMove(
    existing: ?Animation,
    cur_x: i32,
    cur_y: i32,
    target_x: i32,
    target_y: i32,
    duration_ms: u32,
    easing: Easing,
) Animation {
    var sx: f32 = @floatFromInt(cur_x);
    var sy: f32 = @floatFromInt(cur_y);
    var start_opacity: f32 = 1.0;
    var target_opacity: f32 = 1.0;
    var start_scale: f32 = 1.0;
    var target_scale: f32 = 1.0;
    if (existing) |a| {
        sx = a.last_x;
        sy = a.last_y;
        start_opacity = a.last_opacity;
        // Carry the fade's destination so it finishes; for a move that already
        // ended at full opacity this is just 1.0 -> 1.0 (a no-op opacity track).
        target_opacity = a.target_opacity;
        // Likewise carry an in-flight scale pop to its target so it lands at 1.0.
        start_scale = a.last_scale;
        target_scale = a.target_scale;
    }

    return .{
        .kind = .move,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = sx,
        .start_y = sy,
        .target_x = @floatFromInt(target_x),
        .target_y = @floatFromInt(target_y),
        .last_x = sx,
        .last_y = sy,
        .start_opacity = start_opacity,
        .target_opacity = target_opacity,
        .last_opacity = start_opacity,
        .start_scale = start_scale,
        .target_scale = target_scale,
        .last_scale = start_scale,
    };
}

/// True if this animation changes opacity at all (so the driver should apply it).
pub fn fades(anim: Animation) bool {
    return anim.start_opacity != anim.target_opacity;
}

/// Arm an open/close transition at a fixed position: a simultaneous opacity
/// fade and scale pop. `kind` is `.open` (0->1 opacity, 0.65->1 scale) or
/// `.close` (1->0 opacity, 1->0.65 scale). Scale is applied around the window
/// center by the driver.
pub fn armFade(
    kind: Kind,
    x: i32,
    y: i32,
    from_opacity: f32,
    to_opacity: f32,
    from_scale: f32,
    to_scale: f32,
    duration_ms: u32,
    easing: Easing,
) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = kind,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy,
        .target_x = fx,
        .target_y = fy,
        .last_x = fx,
        .last_y = fy,
        .start_opacity = from_opacity,
        .target_opacity = to_opacity,
        .last_opacity = from_opacity,
        .start_scale = from_scale,
        .target_scale = to_scale,
        .last_scale = from_scale,
    };
}

/// True if this animation changes scale at all (so the driver should apply it).
pub fn scales(anim: Animation) bool {
    return anim.start_scale != anim.target_scale or anim.last_scale != 1.0;
}

/// Normalized eased progress at time `now_ns`, clamped to [0,1].
fn progress(anim: Animation, now_ns: i64) f32 {
    if (anim.duration_ns <= 0) return 1.0;
    const elapsed = now_ns - anim.start_ns;
    if (elapsed <= 0) return 0.0;
    if (elapsed >= anim.duration_ns) return 1.0;
    const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(anim.duration_ns));
    return anim.easing.apply(t);
}

/// True once the animation has reached or passed its end time.
pub fn done(anim: Animation, now_ns: i64) bool {
    return now_ns - anim.start_ns >= anim.duration_ns;
}

pub const Sample = struct {
    x: i32,
    y: i32,
    opacity: f32,
    scale: f32,
};

/// Compute the interpolated values at `now_ns` and record them as last-applied.
pub fn sample(anim: *Animation, now_ns: i64) Sample {
    const p = anim.progress(now_ns);
    const x = anim.start_x + (anim.target_x - anim.start_x) * p;
    const y = anim.start_y + (anim.target_y - anim.start_y) * p;
    const o = anim.start_opacity + (anim.target_opacity - anim.start_opacity) * p;
    const sc = anim.start_scale + (anim.target_scale - anim.start_scale) * p;
    anim.last_x = x;
    anim.last_y = y;
    anim.last_opacity = o;
    anim.last_scale = sc;
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
        .opacity = o,
        .scale = sc,
    };
}

/// Apply an opacity to every buffer under `node`. Opacity is a per-SceneBuffer
/// property in wlroots (there is no tree-level opacity), so we walk the subtree.
/// `forEachBuffer` passes the data arg through as `?*anyopaque`, so use a mutable
/// pointer (the callback only reads it).
pub fn applyOpacity(node: *wlr.SceneNode, opacity: f32) void {
    var o = opacity;
    node.forEachBuffer(*f32, setBufferOpacity, &o);
}

fn setBufferOpacity(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, opacity: *f32) void {
    buffer.setOpacity(opacity.*);
}

// --- Scale (around center) -------------------------------------------------
//
// There is no node/tree-level scale in this scene graph; scale lives only on
// SceneBuffer.setDestSize. To scale a window by `f` around its center without
// reconfiguring the client, we:
//   - scale the single surface buffer's dest size to (w*f, h*f), computed from
//     the STABLE natural size `w,h` (the logical box) — never from the buffer's
//     current dest size, which would compound (f^2, f^3, ...) across ticks;
//   - shift the window tree node to box.(x,y) + (1-f)*(w,h)/2 to recenter, so
//     borders and popups (children of the tree) ride along for free.
//
// Windows with more than one surface buffer (subsurfaces — rare for tiled apps)
// are not scaled here (the caller should just fade them). Counting is cheap.

const CountCtx = struct {
    count: u32 = 0,
    last: ?*wlr.SceneBuffer = null,
};

fn countBufferIter(buffer: *wlr.SceneBuffer, _: c_int, _: c_int, ctx: *CountCtx) void {
    ctx.count += 1;
    ctx.last = buffer;
}

/// Number of surface buffers under `node`, and the sole buffer if exactly one.
fn singleBuffer(node: *wlr.SceneNode) ?*wlr.SceneBuffer {
    var ctx: CountCtx = .{};
    node.forEachBuffer(*CountCtx, countBufferIter, &ctx);
    return if (ctx.count == 1) ctx.last else null;
}

pub const ScaleResult = struct {
    /// Position offset to apply to the window tree node so the scale is centered.
    dx: i32,
    dy: i32,
    /// Whether a scale was actually applied (false => caller should not offset).
    applied: bool,
};

/// Apply scale `f` to the single surface buffer under `node`, sized from the
/// stable natural box (nat_w, nat_h). Returns the recentering offset to apply to
/// the window tree node. No-op (applied=false, zero offset) for multi-buffer
/// windows or f == 1.0.
pub fn applyScale(node: *wlr.SceneNode, f: f32, nat_w: i32, nat_h: i32) ScaleResult {
    if (f == 1.0) {
        // Restore natural size in case a prior tick scaled it.
        if (singleBuffer(node)) |buffer| buffer.setDestSize(nat_w, nat_h);
        return .{ .dx = 0, .dy = 0, .applied = false };
    }
    const buffer = singleBuffer(node) orelse return .{ .dx = 0, .dy = 0, .applied = false };
    const fw: f32 = @as(f32, @floatFromInt(nat_w)) * f;
    const fh: f32 = @as(f32, @floatFromInt(nat_h)) * f;
    buffer.setDestSize(@intFromFloat(@round(fw)), @intFromFloat(@round(fh)));
    const dx: f32 = (1.0 - f) * @as(f32, @floatFromInt(nat_w)) / 2.0;
    const dy: f32 = (1.0 - f) * @as(f32, @floatFromInt(nat_h)) / 2.0;
    return .{ .dx = @intFromFloat(@round(dx)), .dy = @intFromFloat(@round(dy)), .applied = true };
}

// ===========================================================================
// Orphan close animations.
//
// A closing window is torn down by the compositor within the next manage+render
// cycle after unmap (manageStart flips .closing -> .init -> makeInert/sendClosed,
// then destroy() frees window.tree) — far sooner than a 200ms fade. So a close
// animation cannot live on the Window (its scene nodes are freed mid-fade).
//
// Instead, at unmap we snapshot the window's buffers into a *standalone* scene
// tree owned by this subsystem (not window.surfaces.saved_tree, whose dropSaved
// would destroy the buffers), arm a fade, and advance it in the same output
// frame loop. The orphan self-destructs when the fade completes; the protocol
// lifecycle of the real window finishes immediately and independently.
//
// Kept deliberately isolated: if the frame-loop damage assumption needs a fix
// after runtime testing, the position tween and this can be fixed separately.
// ===========================================================================

/// A close animation that outlives its Window. Owns its scene tree.
pub const OrphanClose = struct {
    link: wl.list.Link,
    tree: *wlr.SceneTree,
    anim: Animation,
    /// Window origin and natural size, captured at spawn, to scale around center.
    x: i32,
    y: i32,
    nat_w: i32,
    nat_h: i32,

    fn destroy(orphan: *OrphanClose) void {
        orphan.link.remove();
        orphan.tree.node.destroy();
        util.gpa.destroy(orphan);
    }
};

/// Intrusive list of in-flight orphan close animations. Empty in steady state.
var orphans: wl.list.Head(OrphanClose, .link) = undefined;
var orphans_initialized = false;

fn ensureOrphanList() void {
    if (!orphans_initialized) {
        orphans.init();
        orphans_initialized = true;
    }
}

/// Context for copying a window's live buffers into the orphan tree.
const CopyCtx = struct {
    dest: *wlr.SceneTree,
    ok: bool,
};

fn copyBufferIter(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, ctx: *CopyCtx) void {
    // Scene buffers hold a ref on the underlying wlr.Buffer, so the snapshot
    // stays valid after the client's surface is gone — same mechanism river's
    // SaveableSurfaces uses. Mirror dst size / source box / transform so the
    // copy looks identical to what was on screen.
    const sb = ctx.dest.createSceneBuffer(buffer.buffer) catch {
        ctx.ok = false;
        return;
    };
    sb.node.setPosition(sx, sy);
    sb.setDestSize(buffer.dst_width, buffer.dst_height);
    sb.setSourceBox(&buffer.src_box);
    sb.setTransform(buffer.transform);
}

/// Snapshot the buffers under `src_node` into a standalone tree placed at (x,y)
/// in the wm layer, and start a fade-out + shrink (scale 1 -> `to_scale`) around
/// the window center (nat_w, nat_h). No-op if there are no buffers or on
/// allocation failure (the window just disappears, as before).
pub fn spawnClose(
    src_node: *wlr.SceneNode,
    x: i32,
    y: i32,
    nat_w: i32,
    nat_h: i32,
    to_scale: f32,
    duration_ms: u32,
) void {
    ensureOrphanList();

    const tree = server.scene.layers.wm.createSceneTree() catch return;
    tree.node.setPosition(x, y);

    var ctx: CopyCtx = .{ .dest = tree, .ok = true };
    src_node.forEachBuffer(*CopyCtx, copyBufferIter, &ctx);

    // Nothing copied (no buffers, or OOM partway): drop the empty tree.
    if (!ctx.ok or tree.children.empty()) {
        tree.node.destroy();
        return;
    }

    const orphan = util.gpa.create(OrphanClose) catch {
        tree.node.destroy();
        return;
    };
    orphan.* = .{
        .link = undefined,
        .tree = tree,
        // Fade 1 -> 0 and shrink 1 -> to_scale at the captured position.
        .anim = armFade(.close, x, y, 1.0, 0.0, 1.0, to_scale, duration_ms, .ease_in),
        .x = x,
        .y = y,
        .nat_w = nat_w,
        .nat_h = nat_h,
    };
    orphans.append(orphan);

    // unmap runs outside the frame loop, so kick a frame on every output to
    // start advancing this fade.
    scheduleAllOutputFrames();
}

/// Schedule a frame on every powered output. Used to start the animation loop
/// from contexts outside handleFrame (e.g. a close spawned at unmap time).
pub fn scheduleAllOutputFrames() void {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
    }
}

/// Advance all orphan close animations to `now_ns`, applying opacity and
/// destroying any that have finished. Returns true if any remain active.
pub fn advanceOrphans(now_ns: i64) bool {
    if (!orphans_initialized) return false;
    var any_active = false;
    var it = orphans.safeIterator(.forward);
    while (it.next()) |orphan| {
        if (orphan.anim.done(now_ns)) {
            orphan.destroy();
            continue;
        }
        const s = orphan.anim.sample(now_ns);
        applyOpacity(&orphan.tree.node, s.opacity);
        // Shrink around center: scale the buffer and offset the tree to recenter.
        const r = applyScale(&orphan.tree.node, s.scale, orphan.nat_w, orphan.nat_h);
        orphan.tree.node.setPosition(orphan.x + r.dx, orphan.y + r.dy);
        any_active = true;
    }
    return any_active;
}

/// Tear down every in-flight orphan close animation. Call on server shutdown
/// and output destroy so buffers/trees are not leaked and the frame loop does
/// not keep scheduling for orphans that can never be seen.
pub fn destroyAllOrphans() void {
    if (!orphans_initialized) return;
    var it = orphans.safeIterator(.forward);
    while (it.next()) |orphan| orphan.destroy();
}
