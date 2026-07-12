# 0020 - Ghostty app actions are not an awesoMux command surface

## Status

Accepted (INT-25).

## Context

awesoMux embeds libghostty for terminal surfaces but owns a different app
model: one native macOS window, sidebar workspaces, pane splits, SwiftUI/AppKit
menus, a command palette, and `KeyboardShortcutCatalog` as the source of truth
for awesoMux shortcuts.

libghostty can still emit application actions from Ghostty config keybindings,
including new tab/window, close tab/window, split management, goto/resize split,
fullscreen, quit, open/reload config, command palette, and related app chrome
commands. Some names overlap awesoMux concepts but do not map 1:1:

- Ghostty tabs are not awesoMux workspaces in the data model.
- Ghostty windows are not an awesoMux multi-window product direction.
- Ghostty split actions bypass awesoMux's `SessionStore`, close-risk policy,
  sidebar state, and command catalog.
- Ghostty config reload/open actions would bypass awesoMux's layered config
  manager and settings surfaces.

At the same time, awesoMux intentionally loads Ghostty's default config files
for terminal-surface behavior, colors, fonts, and bindings, then layers
awesoMux runtime overrides on top. That means a user can configure Ghostty
bindings that produce these action tags even though awesoMux does not expose
them as app commands.

## Decision

Ghostty application actions are not a parallel awesoMux command surface.

`GhosttyRuntime.action(_:,target:action:)` handles libghostty callbacks that
belong to the terminal surface itself: title, cwd, bell/notification,
mouse/link state, URL/document routing, command-finished, progress, scrollbar,
selection, search state, renderer health, size limits, and quit timers.

Known Ghostty application actions emitted from user `keybind` entries are
claimed and ignored by
`GhosttyRuntime.shouldClaimIgnoredGhosttyApplicationAction(_:)`. Claiming them
returns `true` to libghostty so the action is treated as handled, but awesoMux
does not route those actions into `SessionStore`, AppKit selectors, SwiftUI
commands, or the command palette.

The secure-input callback is explicitly handled as terminal-surface behavior
through a pane-scoped macOS coordinator. Other terminal/system callbacks such
as key tables, key sequences, readonly state, child-exited state, and
prompt-title state stay unclaimed until awesoMux implements explicit handling
for each callback. They are not part of this app-command policy.

The awesoMux command source of truth remains:

- `KeyboardShortcutCatalog`
- the SwiftUI/AppKit File and Workspace command groups
- the command palette actions backed by the same command model
- `docs/shortcuts.md` for user-facing shortcut documentation

The existing menu-binding collision diagnostic stays in place: when a
currently-configured Ghostty keybinding collides with an awesoMux menu
shortcut, `GhosttyRuntime` logs a warning. The warning is diagnostic only; it
does not reorder dispatch or route Ghostty app actions into awesoMux.

## Consequences

- A Ghostty `keybind` such as `super+shift+u=new_split` does not create an
  awesoMux pane split. Users should use awesoMux's menu shortcuts, command
  palette, or future awesoMux shortcut customization for app/workspace/window
  commands.
- If a Ghostty binding uses a chord that awesoMux already claims, the awesoMux
  menu/command path wins first. This ADR describes Ghostty app actions that
  reach libghostty and emit app action tags.
- Ghostty config remains useful for terminal-surface behavior and appearance,
  subject to awesoMux's runtime overrides.
- There is one app-command lifecycle path, so close-risk prompts, sidebar
  selection, pane identity, recently-closed behavior, and accessibility
  announcements stay centralized in awesoMux code.
- Future work that wants Ghostty application actions to drive awesoMux commands
  must change this ADR first, then update `GhosttyRuntime`,
  `KeyboardShortcutCatalog`, `docs/shortcuts.md`, and the command palette
  together.
- Unknown future Ghostty action tags remain unclaimed until awesoMux makes an
  explicit policy decision for them. This prevents a new libghostty action from
  silently looking supported.
