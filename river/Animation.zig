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
    if (existing) |a| {
        sx = a.last_x;
        sy = a.last_y;
        start_opacity = a.last_opacity;
        // Carry the fade's destination so it finishes; for a move that already
        // ended at full opacity this is just 1.0 -> 1.0 (a no-op opacity track).
        target_opacity = a.target_opacity;
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
    };
}

/// True if this animation changes opacity at all (so the driver should apply it).
pub fn fades(anim: Animation) bool {
    return anim.start_opacity != anim.target_opacity;
}

/// Arm a fade at a fixed position. `kind` is `.open` (0 -> 1) or `.close` (1 -> 0).
pub fn armFade(
    kind: Kind,
    x: i32,
    y: i32,
    from_opacity: f32,
    to_opacity: f32,
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
    };
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
};

/// Compute the interpolated values at `now_ns` and record them as last-applied.
pub fn sample(anim: *Animation, now_ns: i64) Sample {
    const p = anim.progress(now_ns);
    const x = anim.start_x + (anim.target_x - anim.start_x) * p;
    const y = anim.start_y + (anim.target_y - anim.start_y) * p;
    const o = anim.start_opacity + (anim.target_opacity - anim.start_opacity) * p;
    anim.last_x = x;
    anim.last_y = y;
    anim.last_opacity = o;
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
        .opacity = o,
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
