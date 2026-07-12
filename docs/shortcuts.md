# Keyboard shortcuts

Default chords below match **[`KeyboardShortcutCatalog`](../Sources/awesoMux/Services/KeyboardShortcutCatalog.swift)** and the **Workspace** / **File** commands in [`AwesoMuxApp`](../Sources/awesoMux/App/AwesoMuxApp.swift). If something drifts, the catalog wins. Users can override bindings in **Settings → Keys**; those overrides are stored in `config.toml` under `[keyboard.shortcuts.<id>]` and feed the menu shortcuts plus command-palette catalog.

**Mental model:** one app window; a **workspace** is a sidebar session (tab idiom); a **pane** is a split inside that session. **⌘W** closes the **pane**, not the window—see [ADR 0002 — Window-close keybinding model](adr/0002-window-close-keybinding-model.md). In the empty welcome state (nothing selected), the same shortcut is titled **Close Window** and dismisses the window. By default, when the target pane has active agent or terminal activity, awesoMux asks before closing it or restarting the single-pane shell.

## File

| Shortcut | Action |
| --- | --- |
| ⌘N | **New Workspace** |
| ⌘W | Routes to a compact terminal first: hides the Floating Panel or minimizes the expanded Terminal Companion without ending its process (a minimized Companion corner tab yields ⌘W back to the pane). When both compact surfaces are open and neither is focused, ⌘W acts on the frontmost. Otherwise, **Close Pane** — or **Close Window** when no session is selected; may ask before interrupting active pane work |

## Workspace menu

### General

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘N | New Workspace | File menu (replaces standard New) |
| ⌥⌘N | New Workspace in Current Directory | Disabled if no session selected |
| ⌃⌘N | New Workspace Group… | Disabled while a sheet is open |
| ⇧⌘R | Rename Workspace… | Disabled if no session selected or sheet open |
| ⇧⌘W | Close Workspace | Closes the selected session (sidebar row); recoverable via Reopen |
| ⇧⌘T | Reopen Closed Workspace | Restores the most recent eligible closed workspace; the **Recently Closed** submenu reaches older entries |
| ⌥⇧⌘W | Clear Workspace | **Permanent** close: always confirms, no reopen entry, terminates the workspace's sessions |

### Panes

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘D | Split Right | |
| ⇧⌘D | Split Down | |
| ⌥⌘[ | Previous Pane | Requires multiple panes |
| ⌥⌘] | Next Pane | Requires multiple panes |
| ⌥⌘= | Grow Active Pane | Requires multiple panes |
| ⌥⌘- | Shrink Active Pane | Requires multiple panes |

*(**Close Pane** is under Workspace; chord is ⌘W via the File-slot binding described in ADR 0002.)*

### Workspaces

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⇧⌘K | Acknowledge Workspace | Clears attention/unread for the *selected* workspace immediately (bypasses [selection dwell](adr/0003-acknowledge-on-selection-dwell.md)) |
| ⌃⌘S | Focus Sidebar | Moves keyboard focus to sidebar search |
| ⌘\\ | Collapse/Expand Sidebar | Collapses to the rail or restores the last non-collapsed width |
| ⌘1…⌘9 | Jump to Workspace 1…9 | Jumps to the corresponding workspace in flattened sidebar order |
| ⇧⌘[ | Previous Workspace | |
| ⇧⌘] | Next Workspace | |

**Clear All Notifications** (same menu) has **no shortcut** today—it calls `acknowledgeAllSessions()`.

### Terminal panels

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘' | **Show Floating Panel** / **Hide Floating Panel** | Per-workspace temporary shell; disabled while a sheet is open. Appends " (running)" when the target workspace's floating slot has work backgrounded |
| ⇧⌘' | **Show Terminal Companion** / **Minimize Terminal Companion** | One terminal companion that keeps its process and directory across workspace switches. ⌘W or the minimize control collapses it to the corner tab; Escape stays available to terminal software. The explicit close control ends it |

### Command palette

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘K | **Show Command Palette** / **Hide Command Palette** | Interceptor-owned shortcut; searches workspaces and actions; disabled while a sheet is open |

### Keyboard cheatsheet

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘/ | **Keyboard Shortcuts** | Opens the searchable shortcuts overlay |

The cheatsheet is also reachable from **Settings → Keys → Show cheatsheet**. Its entries are grouped from `KeyboardShortcutCatalog.settingsSections`, so the Settings pane and overlay share the same shortcut source of truth.

## Ghostty config keybinds

awesoMux loads Ghostty config for terminal behavior and appearance, but Ghostty `keybind` entries are not a second awesoMux app-command surface. Use the shortcuts above, the menus, or the command palette for awesoMux app, workspace, and pane actions.

- If a Ghostty `keybind` uses a chord that awesoMux already claims as a menu shortcut, the awesoMux shortcut wins first.
- If a non-colliding Ghostty `keybind` reaches libghostty and emits an app/window/workspace action such as `new_tab`, `new_split`, `toggle_fullscreen`, `open_config`, or `reload_config`, awesoMux claims and ignores it by design. See [ADR 0020](adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md).

## Modifier legend

| Symbol | Key |
| --- | --- |
| ⌘ | Command |
| ⌥ | Option |
| ⇧ | Shift |
| ⌃ | Control |

## Debug-only

In **DEBUG** builds, the Workspace menu may include developer-only items without stable shortcuts. These are test affordances, not user-facing commands.

| Menu item | Notes |
| --- | --- |
| Debug: Fire Needs Attention on Active Workspace | Sets the selected workspace to `needsAttention` and increments unread count. |
| Debug: Set Active Workspace Waiting | Sets the selected workspace to `waiting` without incrementing unread count; use this to inspect the quiet pause glyph and `Waiting` accessibility labels. |

The normal `./script/build_and_run.sh` launch builds release by default, so these menu items are absent there. Use a DEBUG binary, for example `./script/build_and_run.sh debug`, or stage a debug binary into `dist/awesoMux.app` before opening it.
