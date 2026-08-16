# 0032 — Window versus panel chrome taxonomy

- **Status:** Accepted
- **Date:** 2026-08-15
- **Deciders:** Sarah
- **Issue:** [#372](https://github.com/Interactive-Buffoonery/awesomux/issues/372)

## Context

Seven auxiliary surfaces float above the main window, and they did not agree on
how to be dismissed. Five drew the same hand-rolled `xmark` button but
disagreed on where to put it: About placed it top-left, while Session Manager,
Worktree Manager, the keyboard cheatsheet, and the Terminal Companion placed it
top-right. The remaining two — the Floating Panel and the command palette — had
no visible window controls at all.

The buttons were also inert as keyboard targets. Each declared a focus ring
but none called `.focusable()`, so `isFocused` never became true and the ring
could never render (#372).

Every one of these surfaces is a `.titled` `NSWindow` whose standard window
buttons are merely hidden — none is borderless. Real traffic lights were
therefore always available; the code had simply never asked for them. A spike
confirmed they render correctly on these panels despite `.nonactivatingPanel`,
and that `swiftUIFloatingStyleMask` already yields the intended
close-enabled/minimize-disabled pairing without any style-mask change.

What was missing was not capability but a rule for which surfaces should get
them.

## Decision

Auxiliary surfaces are classified by what they *are*, not by which class hosts
them.

**Window-like surfaces use real AppKit traffic lights at top-left.** These are
surfaces a user reads as a document or an inspector they visit: About, Session
Manager, Worktree Manager, and the keyboard cheatsheet. They opt in via
`FloatingSwiftUIPanelWindow.showsStandardWindowButtons` and draw no close
button of their own. This is the same treatment the Settings window already
receives through `WindowChromeConfigurator`.

**Panel-like surfaces keep custom controls at top-right.** These are surfaces
attached to a running terminal, where the chrome is a thin strip over live
content and the standard titlebar geometry does not fit: the Terminal Companion
and the Floating Panel. They keep purpose-built controls sized and placed for
that strip.

**Transient surfaces get no window controls at all.** The command palette is
summoned, used, and dismissed in one gesture; window controls would imply a
persistence it does not have.

Two consequences follow.

The opt-in must not modify `styleMask`. `swiftUIFloatingStyleMask` deliberately
omits `.miniaturizable`, which is what renders minimize disabled-gray in the
About This Mac manner. Reusing
`StandardWindowButtonVisibility.visible` — which force-unions
`.miniaturizable` — would enable minimize on a floating, fixed-size,
hides-on-deactivate panel and break the intended appearance.

Zoom is disabled explicitly instead. Dropping `.resizable` from the mask would
have rendered it inert too, but `setFixedContentSize` still depends on that
bit. An enabled zoom on a panel whose content size is pinned has nothing to
zoom, yet it still renders green and offers the window-tiling menu on hover,
which would try to move a floating fixed-size panel into a slot it cannot
occupy. Close is therefore the only live control on these surfaces.

The native close must route through the controller. `performClose(_:)` is
overridden to invoke `onDismiss` rather than `close()`, because these panels are
ordered out and reused, and each controller's `dismiss()` owns real teardown:
stopping the Session Manager's polling, refusing to close the Worktree Manager
during an in-flight create, and clearing the `isVisible` flag that app-level
guards depend on. A traffic light wired straight to AppKit's `close()` would
silently bypass all of it.

## Consequences

Three surfaces move their dismissal affordance from top-right to top-left.
This is a deliberate one-time relocation in exchange for matching platform
convention.

Window-family surfaces inherit hover, pressed, and disabled states, keyboard
behavior, and accessibility from AppKit instead of reimplementing them, and
each such surface must reserve leading clearance so its content does not
collide with the lights. The required inset is per-surface, not a single
constant: `AppTitlebarMetrics.trafficLightClearance` is measured from the
window edge, so a header that already carries horizontal padding adds only the
difference, and a surface with centered content and no header row may need
vertical room instead.

Panel-family controls remain our responsibility, including their focus rings.
Those rings render only while macOS "Keyboard navigation" is enabled, which is
the system's focus model rather than a defect.

Adding a new floating surface now requires classifying it first. A surface that
fits none of the three categories is a signal to revisit this decision rather
than to invent a fourth chrome style.

## Alternatives considered

**Real traffic lights everywhere.** Rejected because the terminal panels' header
strips are not titlebars; the Companion's minimize is an app-owned fold to a
corner tab rather than a Dock miniaturize, so a standard button would either
misbehave or need retargeting.

**Custom traffic-light-styled circles everywhere.** Rejected because it
reimplements platform behavior we would then own forever — hover, disabled
states, and accessibility — for surfaces that can simply have the real thing.

**Leaving the chrome as it was and only fixing the focus rings.** This would
have resolved #372's literal defect while leaving the placement inconsistency
and the reimplementation burden in place.

## References

- [ADR-0024](0024-unified-terminal-panel-model.md) — the terminal panels are
  `.titled` windows with stripped chrome
- [ADR-0030](0030-compact-terminal-dismissal-key-model.md) — dismissal key model
  for the compact surfaces
- [ADR-0002](0002-window-close-keybinding-model.md) — app-wide close keybinding
  semantics
