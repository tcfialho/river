// SPDX-License-Identifier: GPL-3.0-only

//! Animation intent: the protocol-level vocabulary the WM uses to declare its
//! intention for a window action. The compositor maps each intent to a concrete
//! tween (easing/duration/effect) at the call sites in Window.zig and Animation.zig.

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

    /// Deck-switch OUT to the LEFT (DECK_PREV): the leaving window slides left
    /// +fade out. Mirror of slide_deck_out (which exits right for DECK_NEXT).
    slide_deck_out_left = 0xc,

    /// Deck-switch IN from the RIGHT (DECK_PREV): the entering window slides in
    /// from the right +fade in +traveling clip. Mirror of slide_in's deck variant
    /// (which enters from the left for DECK_NEXT).
    deck_in_right = 0xd,

    /// Deck-switch IN from the LEFT (DECK_NEXT): the entering window slides in
    /// from the left +fade in +traveling clip. This is the deck-slot entrance for
    /// Win+→; slide_in is now reserved ONLY for the group-open entrance (becomes
    /// main), so the river no longer needs box.x to disambiguate.
    deck_in_left = 0xe,

    /// Lone-window grow reveal: the sole survivor of a close (the last deck window
    /// closed, main expands to fill the screen) is revealed via a growing CLIP
    /// from its old footprint to full width, with a pre-roll delay so it plays
    /// after the close fade. The WM declares this (it knows a window left and only
    /// one visible remains) so the river no longer infers it from grew && count==1.
    grow_reveal = 0xf,
};
