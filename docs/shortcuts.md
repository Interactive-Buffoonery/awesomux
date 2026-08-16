# Keyboard shortcuts

Default chords below match **[`KeyboardShortcutCatalog`](../Sources/awesoMux/Services/KeyboardShortcutCatalog.swift)** and the **File**, **View**, **Workspace**, and **Pane** commands in [`AwesoMuxApp`](../Sources/awesoMux/App/AwesoMuxApp.swift) — the menu bar reads File · Edit · View · Workspace · Pane · Window · Help. If something drifts, the catalog wins. Users can override bindings in **Settings → Keys**; those overrides are stored in `config.toml` under `[keyboard.shortcuts.<id>]` and feed the menu shortcuts plus command-palette catalog.

**Mental model:** one app window; a **workspace** is a sidebar session (tab idiom); a **pane** is a split inside that session. **⌘W** closes the **pane**; on a workspace's last pane it closes the **workspace** instead (soft close, ⇧⌘T reopens)—see [ADR 0002 — Window-close keybinding model](adr/0002-window-close-keybinding-model.md) and its 2026-07-14 amendment. In the empty welcome state (nothing selected), the same shortcut is titled **Close Window** and dismisses the window. By default, awesoMux asks before ⌘W interrupts active agent or terminal activity, whether that closes a pane or the last-pane workspace. To restart a pane's shell in place without closing anything, use the **Restart Shell** command (command palette).

## File

| Shortcut | Action |
| --- | --- |
| ⌘N | **New Workspace** |
| ⌘W | Routes to a compact terminal first: hides the Floating Panel or minimizes the expanded Terminal Companion without ending its process (a minimized Companion corner tab yields ⌘W back to the pane). When both compact surfaces are open and neither is focused, ⌘W acts on the frontmost. Otherwise, **Close Pane** — or **Close Workspace** on a workspace's last pane (soft close, ⇧⌘T reopens), or **Close Window** when no session is selected; may ask before interrupting active pane or workspace work |

## Workspace menu

Workspace lifecycle, navigation, and notifications. Layout presets live here too: they capture a whole workspace's split arrangement, not one pane (see [ADR 0027](adr/0027-named-checked-in-layout-presets.md)).

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌥⌘N | New Workspace in Current Directory | Disabled if no session selected |
| ⌃⌘N | New Workspace Group… | Disabled while a sheet is open |
| ⇧⌘R | Rename Workspace… | Disabled if no session selected or sheet open |
| ⌥⌘P | **Pin Workspace** / **Unpin Workspace** | Pins the selected workspace to the top of the sidebar, or removes it from the pinned section |
| ⇧⌘W | Close Workspace | Closes the selected session (sidebar row); recoverable via Reopen |
| ⇧⌘T | Reopen Closed Workspace | Restores the most recent eligible closed workspace; the **Recently Closed** submenu reaches older entries |
| ⌥⇧⌘W | Clear Workspace | **Permanent** close: always confirms, no reopen entry, terminates the workspace's sessions |
| ⇧⌘K | Acknowledge Workspace | Clears attention/unread for the *selected* workspace immediately (bypasses [selection dwell](adr/0003-acknowledge-on-selection-dwell.md)) |
| ⌘1…⌘9 | Jump to Workspace 1…9 | Jumps to the corresponding workspace in flattened sidebar order. All nine rows are always present; out-of-range ones are disabled, because SwiftUI claims a chord even when the command is disabled |
| ⇧⌘[ | Previous Workspace | |
| ⇧⌘] | Next Workspace | |

**New Workspace** (⌘N) is in the **File** menu, not here — it replaces the standard New item. **Clear All Notifications** in the Workspace menu has **no shortcut** today—it calls `acknowledgeAllSessions()`. **New Remote Workspace Group…**, **Connect via SSH…**, **Make This Workspace Managed…**, **Manage Worktrees…**, **Save Layout as Preset…**, and **Apply Layout Preset…** are unbound.

## Pane menu

Everything scoped to a pane inside the selected workspace: splits, close/rename, find, resize, focus, movement, and the document tab strip.

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌘D | Split Right | Disabled if no session selected |
| ⇧⌘D | Split Down | Disabled if no session selected |
| ⌥⌘R | Rename Pane… | Requires multiple panes |
| ⌘F | Find in Pane | |
| ⇧⌘F | Show Scrollback | Opens the active pane's scrollback dump sheet |
| ⌥⌘= | Grow Active Pane | Requires multiple panes |
| ⌥⌘- | Shrink Active Pane | Requires multiple panes |
| ⌥⌘[ | Previous Pane | Requires multiple panes |
| ⌥⌘] | Next Pane | Requires multiple panes |
| ⌥⌘1…⌥⌘9 | Focus Pane 1…9 | Rows appear only in multi-pane workspaces, and each is disabled past the live pane count so an out-of-range chord never silently no-ops |
| ⌥⌘↑ ⌥⌘↓ ⌥⌘← ⌥⌘→ | Move Pane Up / Down / Left / Right | Moves the active pane to that workspace edge; disabled when the move would be a no-op |
| ⌥⌘S | Swap Pane With Next | Keyboard parity for the center-zone drag-swap |
| ⌃⌘[ | Previous Document Tab | Requires multiple document tabs |
| ⌃⌘] | Next Document Tab | Requires multiple document tabs |
| ⌃⌘W | Close Document Tab | Requires at least one document tab; the strip's per-tab close control refuses first responder, so this is the keyboard route |

*(**Close Pane** is under Pane; its chord is ⌘W via the File-slot binding described in ADR 0002, so the menu row itself carries no key equivalent.)*

## View menu

The sidebar trio, the compact terminal surfaces, the command palette, and Session Manager. AppKit appends its own **Enter Full Screen** below these items.

| Shortcut | Menu item | Notes |
| --- | --- | --- |
| ⌃⌘S | Focus Sidebar | Moves keyboard focus to sidebar search |
| ⌘\\ | Collapse/Expand Sidebar | Collapses to the rail or restores the last non-collapsed width |
| ⇧⌘\\ | Hide/Show Sidebar | Hides the sidebar or restores it persistently |
| ⌘' | **Show Floating Panel** / **Hide Floating Panel** | Per-workspace temporary shell; disabled while a sheet is open. Appends " (running)" when the target workspace's floating slot has work backgrounded |
| ⇧⌘' | **Show Terminal Companion** / **Minimize Terminal Companion** | One terminal companion that keeps its process and directory across workspace switches. ⌘W or the minimize control collapses it to the corner tab; Escape stays available to terminal software. The explicit close control ends it |
| ⌘K | **Show Command Palette** / **Hide Command Palette** | Searches workspaces and actions; disabled while a sheet is open. Registered only as this menu item's key equivalent, which auto-repeats while held, so the menu action carries a repeat guard that swallows the repeats |
| ⇧⌘S | Session Manager | Shows or hides the Session Manager over the main window; disabled while a sheet is open |

⌃⌘S, ⌘\\, and ⇧⌘\\ (plus ⌘/ below) are the four chords intercepted in `AwesoMuxApplication.sendEvent` before main-menu routing, so for those the menu's key equivalent is display-only. Every other chord on this page registers only as a main-menu key equivalent.

## Keyboard cheatsheet

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
