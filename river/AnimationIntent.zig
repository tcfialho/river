const std = @import("std");

/// Animation intent enum — declares WM's intention for this window action.
/// Used by compositor to select easing, duration, and effect (fade/slide/reflow).
pub const Intent = enum(u32) {
    /// No animation — instant geometry update
    none = 0x0,

    /// Open solo window: scale 0.65→1 + opacity 0→1 (fade in)
    fade_open = 0x1,

    /// Close solo window: scale 1→0.65 + opacity 1→0 (fade out)
    fade_close = 0x2,

    /// Close main window with deck visible: translateX -100% left, no fade
    slide_close = 0x3,

    /// Close deck window: translateX +100% right, no fade
    slide_deck_out = 0x4,

    /// Open in group (becomes main or deck): translateX -45%→0 (slide in left)
    slide_in = 0x5,

    /// Geometry change without compositor effect (reflow via CSS ease-in-out)
    /// Used for: deck-next, deck-prev, promote, send-to-bottom, maximize/restore
    reflow_ease = 0x6,

    /// Spring geometry change (cubic-bezier spring)
    /// Used for: swap main↔deck, size adjustments in group
    spring = 0x7,

    /// Focus nudge: small lateral translate ±8px then back
    nudge = 0x8,

    /// Fullscreen carousel: new enters from side, old exits opposite
    fs_carousel = 0x9,

    /// Minimize: translateY +60px, scale 1→0.55, opacity fade down
    minimize = 0xa,

    /// Unminimize: translateY -60px, scale 0.55→1, opacity fade up
    unminimize = 0xb,
};

/// Easing function selector
pub const Easing = enum(u32) {
    linear = 0x0,
    ease_in = 0x1,
    ease_out = 0x2,
    ease_in_out = 0x3,
    cubic_spring = 0x4, // hardcoded: cubic-bezier(0.22, 1, 0.36, 1)
};

/// Per-intent animation configuration (comptime lookup, zero runtime cost)
pub const Config = struct {
    duration_ms: u32,
    easing: Easing,
    /// Which fields are animated in this intent
    animate_opacity: bool,
    animate_scale: bool,
    animate_position: bool,
    animate_size: bool,
    /// Clip-reveal geometry (if applicable)
    use_clip_reveal: bool,
    /// Transform origin for scale-based animations
    scale_origin: enum { center, bottom_center },
};

/// Lookup table: intent → animation config
/// This is populated at comptime; compositor queries during animation setup.
pub fn configForIntent(intent: Intent) Config {
    return switch (intent) {
        .none => .{
            .duration_ms = 0,
            .easing = .linear,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = false,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .fade_open => .{
            .duration_ms = 220,
            .easing = .ease_out,
            .animate_opacity = true,
            .animate_scale = true,
            .animate_position = false,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .fade_close => .{
            .duration_ms = 200,
            .easing = .ease_in,
            .animate_opacity = true,
            .animate_scale = true,
            .animate_position = false,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .slide_close => .{
            .duration_ms = 200,
            .easing = .ease_in,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .slide_deck_out => .{
            .duration_ms = 200,
            .easing = .ease_in,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .slide_in => .{
            .duration_ms = 200,
            .easing = .ease_out,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .reflow_ease => .{
            .duration_ms = 280,
            .easing = .ease_in_out,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = true,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .spring => .{
            .duration_ms = 280,
            .easing = .cubic_spring,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = true,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .nudge => .{
            .duration_ms = 160,
            .easing = .ease_out,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .fs_carousel => .{
            .duration_ms = 240,
            .easing = .cubic_spring,
            .animate_opacity = false,
            .animate_scale = false,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .center,
        },
        .minimize => .{
            .duration_ms = 200,
            .easing = .ease_in,
            .animate_opacity = true,
            .animate_scale = true,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .bottom_center,
        },
        .unminimize => .{
            .duration_ms = 220,
            .easing = .ease_out,
            .animate_opacity = true,
            .animate_scale = true,
            .animate_position = true,
            .animate_size = false,
            .use_clip_reveal = false,
            .scale_origin = .bottom_center,
        },
    };
}

/// Easing function evaluator: progress [0, 1] → eased value [0, 1]
pub fn easeProgress(easing: Easing, t: f32) f32 {
    const clamped_t = std.math.clamp(t, 0.0, 1.0);
    return switch (easing) {
        .linear => clamped_t,
        .ease_in => clamped_t * clamped_t,
        .ease_out => clamped_t * (2.0 - clamped_t),
        .ease_in_out => if (clamped_t < 0.5)
            2.0 * clamped_t * clamped_t
        else
            -1.0 + (4.0 - 2.0 * clamped_t) * clamped_t,
        .cubic_spring => {
            // cubic-bezier(0.22, 1, 0.36, 1) approximation via polynomial
            // For spring effect: slight overshoot on the way out
            const u = clamped_t;
            return 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u) + 0.66 * u * (1.0 - u) * (1.0 - u);
        },
    };
}

/// Intent to human-readable string (for logging)
pub fn intentName(intent: Intent) []const u8 {
    return switch (intent) {
        .none => "NONE",
        .fade_open => "FADE_OPEN",
        .fade_close => "FADE_CLOSE",
        .slide_close => "SLIDE_CLOSE",
        .slide_deck_out => "SLIDE_DECK_OUT",
        .slide_in => "SLIDE_IN",
        .reflow_ease => "REFLOW_EASE",
        .spring => "SPRING",
        .nudge => "NUDGE",
        .fs_carousel => "FS_CAROUSEL",
        .minimize => "MINIMIZE",
        .unminimize => "UNMINIMIZE",
    };
}

/// Easing to human-readable string
pub fn easingName(easing: Easing) []const u8 {
    return switch (easing) {
        .linear => "linear",
        .ease_in => "ease-in",
        .ease_out => "ease-out",
        .ease_in_out => "ease-in-out",
        .cubic_spring => "cubic-spring",
    };
}
