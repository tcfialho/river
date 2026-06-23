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
    /// Focus nudge: a brief lateral bump (0 -> peak -> 0) on the window that
    /// just gained focus. No fade/scale; position only, returning to rest.
    nudge,
    /// P17 directional solid slide: a horizontal glide at fixed opacity and
    /// scale (no fade, no pop). Used for the group-open entrance (slides in
    /// from the left) and the deck/main directional closes (slide out right/
    /// left). Position-only like `move`, but a first-class kind because "slide"
    /// is a distinct visual contract in P17 (3 of the 5 open/close cases) — it
    /// must never fade. The entrance variant additionally sets
    /// `is_entrance_slide` so a mid-glide resize cannot clobber it.
    slide,
};

pub const Easing = enum {
    linear,
    ease_out,
    ease_in,
    /// P15 spring: cubic-bezier(0.22, 1, 0.36, 1) — a sharp ease-out (no
    /// overshoot/bounce despite the name; the control points pull hard toward 1
    /// early). Used for geometry transitions (swap, group grow/shrink).
    spring,
    /// CSS ease-in-out: cubic-bezier(0.42, 0, 0.58, 1) — symmetric S-curve.
    /// Matches the prototype's geometry transition (`left/top/width/height 0.20s
    /// ease-in-out`) bit-for-bit. Used for the MainDeck reflow (maximize, restore,
    /// promote, send-to-bottom, swap).
    ease_in_out,

    /// Map normalized time t in [0,1] to eased progress in [0,1].
    fn apply(easing: Easing, t: f32) f32 {
        return switch (easing) {
            .linear => t,
            // Quadratic ease-out: fast start, gentle stop.
            .ease_out => 1.0 - (1.0 - t) * (1.0 - t),
            // Quadratic ease-in: gentle start, fast stop.
            .ease_in => t * t,
            .spring => cubicBezierYForX(t, 0.22, 1.0, 0.36, 1.0),
            .ease_in_out => cubicBezierYForX(t, 0.42, 0.0, 0.58, 1.0),
        };
    }
};

// Generic cubic-bezier(p1x, p1y, p2x, p2y) with implicit P0=(0,0), P3=(1,1).
// For a given x (= normalized time t), solve x(u)=t for the bezier parameter u,
// then evaluate y(u). Dependency-free. Two curves use this: the spring
// (0.22,1,0.36,1) and the CSS ease-in-out (0.42,0,0.58,1).
//
// Root finding is Newton-Raphson (WebKit UnitBezier approach): x(u) is monotonic
// on [0,1] (both control x-coords are in [0,1]) and well-behaved, so Newton
// converges in ~4 iterations from u0 = x. A bisection fallback covers the cases
// where Newton leaves [0,1] or the derivative is ~0 (flat region). This finds the
// SAME root the old 24-step pure bisection did — the curve, and thus the
// animation feel, is unchanged; only the iteration count drops.

fn bezierAxis(u: f32, c1: f32, c2: f32) f32 {
    const v = 1.0 - u;
    // 3(1-u)^2 u c1 + 3(1-u) u^2 c2 + u^3   (P0=0, P3=1)
    return 3.0 * v * v * u * c1 + 3.0 * v * u * u * c2 + u * u * u;
}

/// d/du of bezierAxis at u (for Newton's method).
fn bezierAxisDeriv(u: f32, c1: f32, c2: f32) f32 {
    const v = 1.0 - u;
    // 3(1-u)^2 c1 + 6(1-u) u (c2 - c1) + 3 u^2 (1 - c2)
    return 3.0 * v * v * c1 + 6.0 * v * u * (c2 - c1) + 3.0 * u * u * (1.0 - c2);
}

/// Solve bezierAxis(u) = x for u in [0,1]. Newton-Raphson with a bisection
/// fallback; converges to the same root as a full bisection sweep.
fn solveBezierU(x: f32, p1x: f32, p2x: f32) f32 {
    var u: f32 = x; // u0 = x is an excellent seed for a near-diagonal x-curve.
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const xu = bezierAxis(u, p1x, p2x) - x;
        if (@abs(xu) < 1e-5) return u;
        const d = bezierAxisDeriv(u, p1x, p2x);
        if (@abs(d) < 1e-6) break; // derivative too small: hand off to bisection.
        u -= xu / d;
        if (u < 0.0 or u > 1.0) break; // left the domain: hand off to bisection.
    }
    // Fallback: a few bisection steps from the full bracket. Reached only for the
    // rare flat-derivative / out-of-domain cases above.
    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    u = x;
    i = 0;
    while (i < 24) : (i += 1) {
        const xu = bezierAxis(u, p1x, p2x);
        if (xu < x) lo = u else hi = u;
        u = (lo + hi) * 0.5;
    }
    return u;
}

/// Evaluate cubic-bezier(p1x, p1y, p2x, p2y) at x in [0,1] (P0=(0,0), P3=(1,1)).
/// Used by .spring (0.22,1,0.36,1) and .ease_in_out (0.42,0,0.58,1) — same solver,
/// different control points, so each curve is bit-exact to its CSS definition.
fn cubicBezierYForX(x: f32, p1x: f32, p1y: f32, p2x: f32, p2y: f32) f32 {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    return bezierAxis(solveBezierU(x, p1x, p2x), p1y, p2y);
}

kind: Kind,
easing: Easing,

/// Monotonic start time and total duration, in nanoseconds.
start_ns: i64,
duration_ns: i64,

/// Optional delay before the animation starts progressing, in nanoseconds. The
/// animation holds at progress 0 (its start state) for this long after start_ns,
/// then runs for duration_ns. Used to sequence the lone-window grow AFTER the
/// close fade so the two don't visually compete. 0 = start immediately.
delay_ns: i64 = 0,

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

/// Nudge peak lateral offset (px). For `.nudge`, the applied x is
/// start_x + nudge_dx * sin(pi * progress): 0 at start/end, peak at the middle.
/// Zero for non-nudge animations.
nudge_dx: f32,

/// Opacity endpoints, in [0,1].
start_opacity: f32,
target_opacity: f32,
last_opacity: f32,

/// Uniform scale endpoints (1.0 = natural size), applied around the window
/// center via SceneBuffer.setDestSize; 1.0 -> 1.0 means "no scale" (pure move).
/// The open/close pop (0.65 <-> 1) lives here.
start_scale: f32,
target_scale: f32,
last_scale: f32,

/// Size-tween endpoints, as a fraction of the *current committed* buffer size
/// per axis. A window growing from old size to new (the client already commits
/// the new-size buffer) starts at old/new (< 1) and ends at 1.0, so the new
/// content appears to zoom from the old footprint. 1.0/1.0 means "no size tween".
/// Composed multiplicatively with the uniform scale above.
start_fx: f32,
start_fy: f32,
last_fx: f32,
last_fy: f32,

/// When true, the per-axis factor (fx) drives a CLIP REVEAL instead of a texture
/// scale: the surface stays at its final committed size (no distortion), and a
/// clip rectangle grows from start_fx*width to full width, revealing the content
/// left-to-right. Used for the lone-window grow (main filling the freed deck
/// space). The driver (Output.advanceAnimations) applies/clears the clip and
/// must clamp the revealed width to the committed buffer to avoid a blank strip.
clip_reveal: bool = false,
preserve_scale_xy: bool = false,
/// True for the group-open ENTRANCE slide (armSlide on a live window). The
/// window enters from off-slot and glides to its target; a resize/move arriving
/// mid-glide (the client committing its real buffer) must NOT clobber this with a
/// no-op armMove(start=target), or the entrance never plays. The driver lets it
/// run to completion. Distinct from a plain reflow move (which has this false).
is_entrance_slide: bool = false,

/// Scale origin: true = bottom-center (minimize/unminimize), false = center
/// (default, all other scale pops). When true, the driver's recenter offset Y
/// is (1-fy)*h instead of (1-fy)*h/2, so the window shrinks toward its bottom
/// edge (toward the taskbar) and grows back up from it. X stays centered.
/// P10 p10Minimize/p10Unminimize use transform-origin: bottom center.
scale_origin_bottom: bool = false,

/// Deck-switch clip-que-viaja (P2.3 p9DeckInLeft/Right): the clip's left edge
/// starts at clip_travel_x px and moves to 0 as the slide reaches its target,
/// so the visible left border stays pinned at the main<->deck division while the
/// window glides in. The driver applies subsurfaceTreeSetClip with x =
/// round(clip_travel_x * (1-progress)). 0 / false = no traveling clip.
clip_travel: bool = false,
clip_travel_x: f32 = 0,
fade_fast: bool = false,

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
/// `start_fx`/`start_fy` are the initial size-tween ratios per axis (old/new of
/// the committed buffer); pass 1.0/1.0 for a pure move with no size change. The
/// size tween always ends at 1.0 (natural).
pub fn armMove(
    existing: ?Animation,
    cur_x: i32,
    cur_y: i32,
    target_x: i32,
    target_y: i32,
    start_fx: f32,
    start_fy: f32,
    duration_ms: u32,
    easing: Easing,
) Animation {
    var sx: f32 = @floatFromInt(cur_x);
    var sy: f32 = @floatFromInt(cur_y);
    var start_opacity: f32 = 1.0;
    var target_opacity: f32 = 1.0;
    var start_scale: f32 = 1.0;
    var target_scale: f32 = 1.0;
    var sfx: f32 = start_fx;
    var sfy: f32 = start_fy;
    var preserve_scale_xy = false;
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
        // If a size tween was mid-flight, continue from where it is so a new
        // layout during the grow/shrink doesn't snap the footprint.
        if (a.last_fx != 1.0 or a.last_fy != 1.0) {
            sfx = a.last_fx;
            sfy = a.last_fy;
        }
        preserve_scale_xy = a.preserve_scale_xy;
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
        .nudge_dx = 0,
        .start_opacity = start_opacity,
        .target_opacity = target_opacity,
        .last_opacity = start_opacity,
        .start_scale = start_scale,
        .target_scale = target_scale,
        .last_scale = start_scale,
        .start_fx = sfx,
        .start_fy = sfy,
        .last_fx = sfx,
        .last_fy = sfy,
        .preserve_scale_xy = preserve_scale_xy,
    };
}

/// True if this animation changes opacity at all (so the driver should apply it).
pub fn fades(anim: Animation) bool {
    return anim.start_opacity != anim.target_opacity;
}

/// True if this animation has a size tween (footprint differs from natural).
pub fn resizes(anim: Animation) bool {
    return anim.start_fx != 1.0 or anim.start_fy != 1.0 or
        anim.last_fx != 1.0 or anim.last_fy != 1.0;
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
        .nudge_dx = 0,
        .start_opacity = from_opacity,
        .target_opacity = to_opacity,
        .last_opacity = from_opacity,
        .start_scale = from_scale,
        .target_scale = to_scale,
        .last_scale = from_scale,
        // open/close has no size tween (footprint is natural throughout).
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
    };
}

/// True if this animation changes scale at all (so the driver should apply it).
pub fn scales(anim: Animation) bool {
    return anim.start_scale != anim.target_scale or anim.last_scale != 1.0;
}

/// Arm a solid horizontal slide from `(x, y)` to `(x + dx, y)`: position only,
/// opacity fixed at 1.0 and scale fixed at 1.0 (no fade, no shrink). Used for the
/// P17 directional closes (deck slides right, main slides left) on the orphan
/// snapshot, and reused conceptually by the group open slide-in on the live node.
/// The window appears to slide off as a solid panel — the opposite of the center
/// fade. `dx` is a logical-pixel delta (typically ± the window width).
pub fn armSlide(x: i32, y: i32, dx: f32, duration_ms: u32, easing: Easing) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .slide,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy,
        .target_x = fx + dx,
        .target_y = fy,
        .last_x = fx,
        .last_y = fy,
        .nudge_dx = 0,
        // Solid slide: opacity and scale are held constant (no fade/pop).
        .start_opacity = 1.0,
        .target_opacity = 1.0,
        .last_opacity = 1.0,
        .start_scale = 1.0,
        .target_scale = 1.0,
        .last_scale = 1.0,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
    };
}

/// Arm a minimize: slide DOWN by `dy` px + shrink from `from_scale` to
/// `to_scale` + fade from `from_op` to `to_op`, with scale origin at the
/// BOTTOM center (P10 p10Minimize: translateY 0->60, scale 1->0.55, opacity
/// 1->0, 200ms ease-in, transform-origin: bottom center).
pub fn armMinimize(
    x: i32,
    y: i32,
    dy: f32,
    from_scale: f32,
    to_scale: f32,
    from_op: f32,
    to_op: f32,
    duration_ms: u32,
    easing: Easing,
) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .move,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy,
        .target_x = fx,
        .target_y = fy + dy,
        .last_x = fx,
        .last_y = fy,
        .nudge_dx = 0,
        .start_opacity = from_op,
        .target_opacity = to_op,
        .last_opacity = from_op,
        .start_scale = from_scale,
        .target_scale = to_scale,
        .last_scale = from_scale,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
        .scale_origin_bottom = true,
    };
}

/// Arm an unminimize: the mirror of armMinimize — slide UP from `dy` below the
/// rest position, grow from `from_scale` to `to_scale`, fade in. Scale origin
/// at the BOTTOM center (P10 p10Unminimize: translateY 60->0, scale 0.55->1,
/// opacity 0->1, 220ms ease-out, transform-origin: bottom center).
/// Caller passes the REST position (x, y); start_y is y+dy, target_y is y.
pub fn armUnminimize(
    x: i32,
    y: i32,
    dy: f32,
    from_scale: f32,
    to_scale: f32,
    from_op: f32,
    to_op: f32,
    duration_ms: u32,
    easing: Easing,
) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .move,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy + dy,
        .target_x = fx,
        .target_y = fy,
        .last_x = fx,
        .last_y = fy + dy,
        .nudge_dx = 0,
        .start_opacity = from_op,
        .target_opacity = to_op,
        .last_opacity = from_op,
        .start_scale = from_scale,
        .target_scale = to_scale,
        .last_scale = from_scale,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
        .scale_origin_bottom = true,
    };
}

/// Arm a deck-switch OUT (the window leaving the deck slot): a short lateral
/// slide of `dx` px (positive = right for DECK_NEXT, negative = left for
/// DECK_PREV) with a fade out, no scale. P2.3 p9DeckOutRight/Left: 130ms ease-in,
/// opacity 1->0. Used via spawnDeckOut (orphan tree) since the live window is
/// being hidden, not destroyed.
pub fn armDeckOut(x: i32, y: i32, dx: f32, duration_ms: u32, easing: Easing) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .slide,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy,
        .target_x = fx + dx,
        .target_y = fy,
        .last_x = fx,
        .last_y = fy,
        .nudge_dx = 0,
        // Solid slide out + fade: opacity 1 -> 0, scale fixed 1.
        .start_opacity = 1.0,
        .target_opacity = 0.0,
        .last_opacity = 1.0,
        .start_scale = 1.0,
        .target_scale = 1.0,
        .last_scale = 1.0,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
        .clip_travel = false,
        .clip_travel_x = 0.0,
        .fade_fast = true,
    };
}

/// Arm a deck-switch IN (the window entering the deck slot): a lateral slide
/// of `dx` px (negative = from the left for DECK_NEXT, positive = from the
/// right for DECK_PREV) with a fade in and a traveling clip. P2.3 p9DeckInLeft/
/// Right: 200ms ease-out, opacity 0->1, clip-path inset left travels from
/// |dx| to 0. The clip pins the visible left border at the main<->deck division
/// so the window does not appear to cross over the main slot.
pub fn armDeckIn(x: i32, y: i32, dx: f32, duration_ms: u32, easing: Easing) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .slide,
        .easing = easing,
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx + dx,
        .start_y = fy,
        .target_x = fx,
        .target_y = fy,
        .last_x = fx + dx,
        .last_y = fy,
        .nudge_dx = 0,
        // Slide in + fade in: opacity 0 -> 1, scale fixed 1.
        .start_opacity = 0.0,
        .target_opacity = 1.0,
        .last_opacity = 0.0,
        .start_scale = 1.0,
        .target_scale = 1.0,
        .last_scale = 1.0,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
        .clip_travel = (dx < 0.0),
        .clip_travel_x = if (dx < 0.0) @abs(dx) else 0.0,
    };
}

/// Arm a focus nudge: a brief lateral bump of `peak_dx` px around the resting
/// position (x, y), returning to rest. Position only — no fade, no scale.
pub fn armNudge(x: i32, y: i32, peak_dx: f32, duration_ms: u32) Animation {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return .{
        .kind = .nudge,
        .easing = .linear, // the sine shape comes from sample(), not the easing
        .start_ns = nowNs(),
        .duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms,
        .start_x = fx,
        .start_y = fy,
        .target_x = fx,
        .target_y = fy,
        .last_x = fx,
        .last_y = fy,
        .nudge_dx = peak_dx,
        .start_opacity = 1.0,
        .target_opacity = 1.0,
        .last_opacity = 1.0,
        .start_scale = 1.0,
        .target_scale = 1.0,
        .last_scale = 1.0,
        .start_fx = 1.0,
        .start_fy = 1.0,
        .last_fx = 1.0,
        .last_fy = 1.0,
    };
}

/// Normalized eased progress at time `now_ns`, clamped to [0,1].
pub fn progress(anim: Animation, now_ns: i64) f32 {
    if (anim.duration_ns <= 0) return 1.0;
    // Hold at 0 during the optional pre-roll delay, then measure from its end.
    const elapsed = now_ns - anim.start_ns - anim.delay_ns;
    if (elapsed <= 0) return 0.0;
    if (elapsed >= anim.duration_ns) return 1.0;
    const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(anim.duration_ns));
    return anim.easing.apply(t);
}

/// True once the animation has reached or passed its end time (delay included).
pub fn done(anim: Animation, now_ns: i64) bool {
    return now_ns - anim.start_ns >= anim.delay_ns + anim.duration_ns;
}

pub const Sample = struct {
    x: i32,
    y: i32,
    opacity: f32,
    scale: f32,
    /// Per-axis size-tween factor (start_fx/fy -> 1.0). Composed with `scale`.
    fx: f32,
    fy: f32,
};

/// Compute the interpolated values at `now_ns` and record them as last-applied.
pub fn sample(anim: *Animation, now_ns: i64) Sample {
    const p = anim.progress(now_ns);
    // Nudge: a transient lateral bump that returns to rest — peak*sin(pi*p),
    // which is 0 at p=0 and p=1 and peaks at p=0.5. (nudge_dx is 0 otherwise.)
    const bump: f32 = if (anim.nudge_dx != 0)
        anim.nudge_dx * @sin(std.math.pi * p)
    else
        0;
    const x = anim.start_x + (anim.target_x - anim.start_x) * p + bump;
    const y = anim.start_y + (anim.target_y - anim.start_y) * p;
    const op_factor = if (anim.fade_fast) @sqrt(p) else p;
    const o = anim.start_opacity + (anim.target_opacity - anim.start_opacity) * op_factor;
    const sc = anim.start_scale + (anim.target_scale - anim.start_scale) * p;
    // Size tween always lands on 1.0 (natural footprint).
    const sfx = anim.start_fx + (1.0 - anim.start_fx) * p;
    const sfy = anim.start_fy + (1.0 - anim.start_fy) * p;
    anim.last_x = x;
    anim.last_y = y;
    anim.last_opacity = o;
    anim.last_scale = sc;
    anim.last_fx = sfx;
    anim.last_fy = sfy;
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
        .opacity = o,
        .scale = sc,
        .fx = sfx,
        .fy = sfy,
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

/// Reveal the surface under `node` left-to-right via a growing clip rectangle of
/// width `frac * full_w` (clamped to the committed buffer width to avoid a blank
/// strip on the right when the client hasn't drawn the full size yet). Height is
/// always full. `frac` in (0,1]. The content is NOT scaled — it stays at its
/// committed size, so there is no distortion. Pass frac >= 1.0 (or call
/// clearClipReveal) to remove the clip. No-op if not a single-buffer surface.
pub fn applyClipReveal(tree: *wlr.SceneTree, frac: f32, full_w: i32, full_h: i32) void {
    var revealed: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(full_w)) * frac));
    // Clamp to the buffer the client has actually committed: revealing past it
    // would expose an empty region (the "stripes on the right").
    if (singleBuffer(&tree.node)) |buffer| {
        if (buffer.buffer) |buf| {
            if (revealed > buf.width) revealed = buf.width;
        }
    }
    if (revealed < 1) revealed = 1;
    const clip: wlr.Box = .{ .x = 0, .y = 0, .width = revealed, .height = full_h };
    if (!tree.children.empty()) {
        tree.node.subsurfaceTreeSetClip(&clip);
    }
}

/// Remove any clip applied by applyClipReveal (restore the full surface).
pub fn clearClipReveal(tree: *wlr.SceneTree) void {
    const empty: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (!tree.children.empty()) {
        tree.node.subsurfaceTreeSetClip(&empty);
    }
}

/// Apply per-axis factors `fx`/`fy` to the single surface buffer under `node`,
/// sized from the stable natural box (nat_w, nat_h). Used for both the uniform
/// pop (fx == fy) and the non-uniform size tween (fx != fy). Returns the
/// recentering offset for the window tree node. No-op (applied=false) for
/// multi-buffer windows or fx == fy == 1.0.
pub fn applyScaleXY(node: *wlr.SceneNode, fx: f32, fy: f32, nat_w: i32, nat_h: i32) ScaleResult {
    if (fx == 1.0 and fy == 1.0) {
        // Restore AUTO sizing, not a fixed size. A scene_surface only re-tracks
        // the client's committed buffer size while dst is (0,0) — see wlroots
        // wlr_scene.c:912 (`dst_width == 0 && dst_height == 0`). Writing a fixed
        // dst here (e.g. nat_w from box.width = the size committed SO FAR) freezes
        // the surface: in a deck->main swap the client hasn't committed the larger
        // buffer yet, so the window stays small with garbage in the uncovered slot
        // (the "stripes on the right") until a later render re-finishes. Passing
        // (0,0) re-enables auto-tracking so the new buffer is reflected the instant
        // it lands, no focus change needed. nat_w/nat_h are unused in this branch.
        if (singleBuffer(node)) |buffer| buffer.setDestSize(0, 0);
        return .{ .dx = 0, .dy = 0, .applied = false };
    }
    const buffer = singleBuffer(node) orelse return .{ .dx = 0, .dy = 0, .applied = false };
    const fw: f32 = @as(f32, @floatFromInt(nat_w)) * fx;
    const fh: f32 = @as(f32, @floatFromInt(nat_h)) * fy;
    buffer.setDestSize(@intFromFloat(@round(fw)), @intFromFloat(@round(fh)));
    const dx: f32 = (1.0 - fx) * @as(f32, @floatFromInt(nat_w)) / 2.0;
    const dy: f32 = (1.0 - fy) * @as(f32, @floatFromInt(nat_h)) / 2.0;
    return .{ .dx = @intFromFloat(@round(dx)), .dy = @intFromFloat(@round(dy)), .applied = true };
}

/// Uniform convenience wrapper (pop): same factor on both axes.
pub fn applyScale(node: *wlr.SceneNode, f: f32, nat_w: i32, nat_h: i32) ScaleResult {
    return applyScaleXY(node, f, f, nat_w, nat_h);
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

/// How a closing window should leave: the P17 close matrix.
///   - fade: solo close — fade out + shrink to `to_scale` around center (no move).
///   - slide_right: deck close — slide one full width to the RIGHT, opacity 1,
///     no shrink (a solid carousel exit; mirror of the group open slide-in).
///   - slide_left: main-with-deck close — slide one full width to the LEFT,
///     opacity 1, no shrink.
pub const CloseStyle = enum { fade, slide_right, slide_left };

/// Snapshot the buffers under `src_node` into a standalone tree placed at (x,y)
/// in the wm layer, and start the close transition selected by `style` (see
/// CloseStyle). No-op if there are no buffers or on allocation failure (the
/// window just disappears, as before).
pub fn spawnClose(
    src_node: *wlr.SceneNode,
    x: i32,
    y: i32,
    nat_w: i32,
    nat_h: i32,
    to_scale: f32,
    duration_ms: u32,
    style: CloseStyle,
    easing: Easing,
) void {
    ensureOrphanList();

    // Use the dedicated close_overlay layer (above live windows, below the bar)
    // so the fade is not occluded by a window the WM raises into the same slot.
    const tree = server.scene.layers.close_overlay.createSceneTree() catch return;
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

    // P17 close matrix: solo fades+shrinks in place; deck/main slide one full
    // width sideways at full opacity (solid), no shrink. The slide target is a
    // horizontal delta from the captured origin; sample() interpolates x toward
    // it and advanceOrphans applies the sampled x.
    const slide_dx: f32 = switch (style) {
        .fade => 0,
        .slide_right => @floatFromInt(nat_w),
        .slide_left => @floatFromInt(-nat_w),
    };
    const anim: Animation = switch (style) {
        // Fade 1 -> 0 and shrink 1 -> to_scale at the captured position.
        .fade => armFade(.close, x, y, 1.0, 0.0, 1.0, to_scale, duration_ms, easing),
        // Slide: opacity fixed 1, scale fixed 1, x: 0 -> slide_dx (from origin).
        .slide_right, .slide_left => armSlide(x, y, slide_dx, duration_ms, easing),
    };
    orphan.* = .{
        .link = undefined,
        .tree = tree,
        .anim = anim,
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

/// Snapshot the buffers under `src_node` into a standalone close_overlay tree
/// and animate a deck-switch OUT: a short lateral slide of `dx` px (positive =
/// right for DECK_NEXT, negative = left for DECK_PREV) with a fade out, no
/// shrink (P2.3 p9DeckOutRight/Left: 130ms ease-in, opacity 1->0). Used when a
/// window leaves the deck slot and is hidden (not destroyed) — the live window
/// is disabled underneath, the orphan carries the exit animation and self-
/// destructs. No-op if there are no buffers or on allocation failure.
pub fn spawnDeckOut(
    src_node: *wlr.SceneNode,
    x: i32,
    y: i32,
    nat_w: i32,
    nat_h: i32,
    dx: f32,
    duration_ms: u32,
    easing: Easing,
) void {
    ensureOrphanList();

    const tree = server.scene.layers.close_overlay.createSceneTree() catch return;
    tree.node.setPosition(x, y);

    var ctx: CopyCtx = .{ .dest = tree, .ok = true };
    src_node.forEachBuffer(*CopyCtx, copyBufferIter, &ctx);

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
        .anim = armDeckOut(x, y, dx, duration_ms, easing),
        .x = x,
        .y = y,
        .nat_w = nat_w,
        .nat_h = nat_h,
    };
    orphans.append(orphan);

    scheduleAllOutputFrames();
}

/// Snapshot the buffers under `src_node` into a standalone close_overlay tree
/// and animate a minimize: slide DOWN by `dy` px + shrink from 1 to `to_scale`
/// around the BOTTOM center + fade out (P10 p10Minimize: translateY 0->60,
/// scale 1->0.55, opacity 1->0, 200ms ease-in, origin bottom center). Used when
/// a window is minimized (removed from the visible set) — the live window is
/// hidden underneath, the orphan carries the exit and self-destructs. No-op if
/// no buffers / OOM.
pub fn spawnMinimize(
    src_node: *wlr.SceneNode,
    x: i32,
    y: i32,
    nat_w: i32,
    nat_h: i32,
    dy: f32,
    to_scale: f32,
    duration_ms: u32,
    easing: Easing,
) void {
    ensureOrphanList();

    const tree = server.scene.layers.close_overlay.createSceneTree() catch return;
    tree.node.setPosition(x, y);

    var ctx: CopyCtx = .{ .dest = tree, .ok = true };
    src_node.forEachBuffer(*CopyCtx, copyBufferIter, &ctx);

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
        .anim = armMinimize(x, y, dy, 1.0, to_scale, 1.0, 0.0, duration_ms, easing),
        .x = x,
        .y = y,
        .nat_w = nat_w,
        .nat_h = nat_h,
    };
    orphans.append(orphan);

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
        // Shrink around center (solo fade only): scale the buffer and recenter.
        // For a slide, scale is 1.0 so applyScale is a no-op (r.dx = 0). The
        // sampled x/y carry the slide (start -> start+dx); the fade close keeps
        // s.x == orphan.x (armFade fixes target_x = x), so this also covers it.
        const r = applyScale(&orphan.tree.node, s.scale, orphan.nat_w, orphan.nat_h);
        var oy: i32 = r.dy;
        // Minimize orphan: scale origin at the BOTTOM center, not the center, so
        // the shrink goes toward the bottom edge (toward the taskbar). Override
        // the center recenter dy = (1-scale)*h/2 with (1-scale)*h. P10 origin.
        if (orphan.anim.scale_origin_bottom) {
            const h_f: f32 = @floatFromInt(orphan.nat_h);
            oy = @intFromFloat(@round((1.0 - s.scale) * h_f));
        }
        orphan.tree.node.setPosition(s.x + r.dx, s.y + oy);
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
