# Native dropdown fixture

Run `./script/menu-styling-e2e/run.sh`, then open the printed app path. This
standalone app links the production design system and uses symlinks to the
production dropdown, presenter, styles, and floating-window implementation.
It does not open a terminal, start an agent, use saved app state, or change
system settings. The native Menu is a representative before control; the
styled control is the production component with fixture callbacks.

Check keyboard opening, arrows, Return, Space, typed prefixes (including a
space), Escape, a second click on the trigger, outside clicks, a disabled menu
and row, a 600-choice scrolling list, light/dark and enlarged text.
The list starts at Choice 599 and mixes wrapped and single-line rows. Open it,
scroll to both ends, select a row, and reopen it. Repeat with Fonts, which uses
the installed font-family names and a separator. Menus must stay within their
360-point viewport, compact menus must shrink, and neither case may show
continuous size jitter or an exception. The result
label identifies the action and picker value. A disabled action deliberately
prints `BUG: disabled action` if its gate fails.

The Floating host uses the production `FloatingSwiftUIPanelWindow`, including
its normal dismissal behavior. Its menu must open above the host, and Escape
must return to the still-open host. Sheet host checks the same actions inside
a SwiftUI sheet. Close the fixture windows when finished.

Screenshots under `docs/images/button-menus/` are captures from this native
fixture. They establish appearance of the shared production component, not
provider behavior or every production caller. AX state and keyboard checks do
not establish VoiceOver speech.
