# Button-opened menu styling audit

Audited on 2026-11-08. Scope: menus opened by app buttons and dropdown selectors.
macOS menu-bar, Dock, terminal right-click, and other context menus retain native
presentation. Segmented, radio, color, and system file/emoji pickers are not
button-opened action menus.

## Inventory

| Surface | Previous revealed content | Treatment |
| --- | --- | --- |
| Path bar: branch switcher, editor/Finder/copy-path, remote status | App chrome fill, accent hairline, overlay shadow, themed rows | Reference styling; shared styles extracted without changing appearance |
| Sidebar: Agents + and collapsed workspace + | Native SwiftUI Menu; themed trigger only | Shared app dropdown |
| Sidebar: workspace split-button options | Native SwiftUI Menu; themed trigger only | Shared app dropdown; group choices appear inline under their heading |
| Sidebar: Help and feedback | Native SwiftUI Menu; themed trigger only | Shared app dropdown |
| Sidebar: Update Available | AppKit NSMenu; themed indicator | Shared app dropdown with version-bearing accessibility label |
| Worktree manager: Open destinations | Native SwiftUI Menu with primary action | Direct Open button plus themed destination dropdown |
| Worktree creation: branch and destination | Native Picker | Shared app dropdown picker |
| SSH connection: Remember… | Native SwiftUI Menu | Shared app dropdown; validation, enablement, and disabled hints retained |
| SSH helper: remember choice for host/all hosts | Native Picker | Shared app dropdown picker |
| Settings: interface and terminal font | Themed trigger with native SwiftUI Menu | Shared app dropdown, selected checkmarks, existing missing-font fallback |
| Settings: terminal theme | Native menu Picker | Shared app dropdown picker |
| Settings: remote helper installation policy | Native Picker | Shared app dropdown picker |
| Agent setup: provider | Native Picker | Shared app dropdown picker |
| Assistant access: exact pane | Native Picker | Shared app dropdown picker |
| Diagnostics: event category | Native Picker | Shared app dropdown picker |
| Markdown comments, link preview, transcript browser, quick settings and utility panels | Custom content with existing app typography/surfaces | Retained; these are content panels rather than action menus |

## Implementation and acceptance

`AppMenuChrome` and `AppMenuRowButtonStyle` are extracted from the path bar.
`AppDropdown` uses an anchored, transparent AppKit panel and draws the opaque app
surface itself. A key-capable panel avoids system popover material and arrow-key
dismissal. It closes on outside click, loss of key status, app deactivation, and
parent window movement, resizing, minimization, or closure. Rows use the existing app font and color
tokens. Long lists render lazily and scroll; arrow navigation skips disabled choices and wraps.
Picker selections show checkmarks; empty pickers are disabled. Full option labels wrap. Selecting an action dismisses before invoking
its existing callback. Typed selection accepts punctuation and spaces. Activation
ignores held-key repeats. Mouse-opened menus restore the previous responder;
keyboard-opened menus preserve the trigger focus. Empty group lists still offer creation of a new group.

Check in the running native host: short and long lists, light and dark appearance,
keyboard opening/navigation/activation/Escape, outside-click dismissal, disabled
choices, selection checks, and accessible labels. Automated navigation tests alone
do not establish native focus or VoiceOver behavior.

## Recorded validation

The standalone native fixture verified ordinary and disabled choices, selected
picker updates, arrows/Return/Escape, prefix matching with spaces and punctuation
(`Choice 599` in 600 options and `feature/b`), lazy-list AX option exposure,
wrapped labels in light/dark appearance, floating-host survival and focus return,
and a choice inside a SwiftUI sheet. The focus-preservation scenario opened a
menu while an input contained `kept`, dismissed it, typed `x`, and observed
`keptx` in the same input. This checks responder restoration without touching a
live terminal or saved workspace.

These observations do not establish VoiceOver speech, every production caller,
multiple-display edge placement, held-key hardware repeat behavior, or an isolated
performance benchmark. Opening the 600-choice lazy fixture plus AX observation
returned in under one second in the observed run; that includes automation and
must not be treated as application latency profiling.

## Font-picker constraint-loop follow-up

The Air reported an `NSGenericException` on macOS 27.2 (26B123), commit
`14d543b9`, for excessive Update Constraints in Window passes in a 312 × 404
`DropdownPanel`. The interaction that triggered the exception was not recorded.
The exact exception has not reproduced locally.

A variable-height 600-row fixture confirmed an unnecessary feedback path:
scrolling changed the lazy stack estimate from 36,296 to 36,345 points and
caused two presenter updates while the visible menu stayed capped at 360 points.
The presenter previously forced layout and fitting-size measurement on every
update. The fix clamps the geometry value before storing it, supplies the
known viewport size plus shadow padding directly, and resizes only when that
size changes. The same scroll caused zero presenter updates after the change.
Temporary counters were removed.

The native fixture now includes installed font names and mixed-height rows
with an initially offscreen selection. This demonstrates the feedback-path
change; it does not establish reproduction or elimination of the Air's exact
interaction.

The Remote helper settings binding ignores an unchanged global policy, so
reselecting its checked choice does not clear saved host-specific preferences.
Changing the global policy still clears those overrides as before. This guard
is local to that binding: generic pickers keep invoking their setters because
projected bindings such as exact-pane access use them to normalize backing state.
