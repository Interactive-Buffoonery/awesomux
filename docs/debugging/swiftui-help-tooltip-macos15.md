# SwiftUI `.help()` tooltip timing on macOS 15+

**2026-07-12 — tooltip delay could not be influenced; approach abandoned.**

Goal at the time: make a collapsed sidebar group header's native tooltip show the
group name, and shorten its roughly 2.5s appearance delay.

Neither lever worked:

- `UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1500])` did
  not change the observed delay.
- `.contentShape(Rectangle())` did not visibly widen the hover hit area.

Root cause unconfirmed. The suspicion is that SwiftUI's `.help()` on macOS 15+
does not route through classic AppKit `NSToolTipManager` timing at all, so the
defaults key never reaches it. The code was reverted and the approach abandoned
in favour of a custom floating peek card (`SidebarGroupPeekCard`).

**Do not re-chase tooltip timing without new evidence.**

## The related bug that was real

The "hover only works right on top of the colored bar" symptom reported
alongside this was *not* a missing `.contentShape`. The collapsed header row
reserved `.frame(minHeight: 14)` for content occupying roughly 2.5–8 pt — that
undersized frame was the hit-area bug. It is now `minHeight: 26`.

Worth remembering as a shape: a hover/hit-test complaint on a compact row is more
likely a reserved-height problem than a hit-shape problem.
