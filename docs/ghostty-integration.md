# Ghostty Integration

awesoMux vendors Ghostty as a pinned git submodule:

- Path: `vendor/ghostty`
- Upstream: `https://github.com/ghostty-org/ghostty.git`
- Current pin: `ad692f1e858b8c6475aec4539934526a8d783e6d` (untagged `origin/main`, post-`v1.3.1`)
- License: MIT

> Pinned past `v1.3.1` to pick up upstream resize/reflow fixes (notably
> `#12653` "preserve shell prompts on resize") and the VT throughput work
> (`#13209`/`#13220`/`#13226` — parser-bound IO plus print/CSI fast paths).
> INT-732 measured a ~40x end-to-end win for sustained plain-ASCII output in
> a single dev session (150MB `cat`: 77–235s before, ~1.8s after; UTF-8-heavy
> content gains far less — see PR #551 for methodology and caveats).
> This exact commit is the last `main` commit before upstream's scrollback
> compression series landed — chosen to take every throughput fix while
> excluding a then-days-old subsystem still receiving correctness fixes.
> Revisit the exclusion (and a release tag) on the next pin bump.

The integration uses Ghostty's Darwin XCFramework output,
`macos/GhosttyKit.xcframework`, produced under `.build/ghostty/` and linked from
the SwiftPM app via the `GhosttyKit` system-library module and
`GhosttyKitLinker` target (see `Package.swift`).

## Build The XCFramework

Prerequisites:

- Full Xcode selected with `xcode-select`.
- Zig available on `PATH`.
- Ghostty submodules initialized if its build asks for them.

```sh
./script/build_ghostty_xcframework.sh
```

The script builds the native macOS XCFramework only, which is faster than a
universal Apple-platform framework and enough for the first local awesoMux
terminal spike.

Since the pin bump, Ghostty combines libghostty and all of its C/C++ dependency
archives into a single `libghostty-internal-fat.a` (copied here as
`libghostty-fat.a`), which the app force-loads alone — there are no longer
per-dependency archives staged under `.build/ghostty/lib/`.
Run this script before `swift build` or `swift test` on a fresh checkout. The
app run script does this automatically if the local archives are missing.

The script publishes atomically: artifacts are assembled under a transient
`.build/ghostty/.staging.<pid>/` directory and swapped into place at the end.
Stray `.staging*` or `*.old` entries under `.build/ghostty/` are leftovers
from an interrupted run — safe to delete, and cleaned up automatically on the
next build.

## Runtime Resources

`script/build_and_run.sh` stages Ghostty's generated `zig-out/share` tree into
`dist/awesoMux.app/Contents/Resources`. This gives libghostty the macOS bundle
layout it expects, and it stages bundled terminal fonts under the app-specific
font path declared in `Info.plist`:

- `Contents/Resources/terminfo/78/xterm-ghostty`
- `Contents/Resources/ghostty/shell-integration`
- `Contents/Resources/Fonts/HackNerdFontMono/*.ttf`
- `Contents/Resources/awesoMux_DesignSystem.bundle/Fonts/Geist-*.ttf`

The Hack Nerd Font Mono files and their license are committed directly under
`Resources/Fonts/HackNerdFontMono/`. The project does not use Git LFS or a
download step for these runtime assets, so an ordinary recursive clone contains
everything needed to stage the font bundle.

With those resources present, child shells can use Ghostty's terminfo and
automatic shell integration instead of falling back to `xterm-256color`.
New configs default the terminal font family to the bundled
`Hack Nerd Font Mono`; users can pick a different installed family or
fall back to the system default in Appearance settings. Terminal
typography lives entirely under Appearance now — the Terminal pane
keeps only terminal-specific toggles like cursor and CRT behavior.

The four unmodified Geist Sans 1.8.0 static UI weights are committed directly
under `Sources/DesignSystem/Resources/Fonts/` and copied into the DesignSystem
SwiftPM resource bundle. The app staging script copies that bundle into the app
under `Contents/Resources`; `DesignSystemFonts` resolves that signed-app layout
before falling back to SwiftPM's generated development bundle lookup. The app
registers the faces for the process at launch. Like the terminal font, an
ordinary clone contains the complete payload without Git LFS or a private asset
fetch.

Note: picking a Mono font in Appearance fully owns the family stack —
awesoMux resets `font-family`, `font-family-bold`, `font-family-italic`,
and `font-family-bold-italic` before applying its choice, so any
matching keys in a user's `~/.config/ghostty/config` are overridden.
Choose the `System default` option to skip awesoMux's family override
entirely and let your Ghostty config and CoreText resolution stand.

## Terminal Color Identity

Terminal appearance is split between visual config and terminal identity:

- `ghostty` terminal background mode leaves foreground/palette/background
  colors owned by Ghostty or the user's Ghostty config, while awesoMux still
  advertises the effective light/dark terminal identity.
- `catppuccinTheme` and `custom` terminal background modes are awesoMux-owned
  color modes. In those modes awesoMux emits the matching Catppuccin background,
  foreground, palette, cursor, and selection colors into the generated Ghostty
  config override.
- Every surface spawn advertises terminal color capability with
  `TERM=xterm-ghostty`, `COLORTERM=truecolor`, and a light/dark `COLORFGBG`.
- Identity and capability are deliberately split: `TERM_PROGRAM=awesoMux` (with
  `TERM_PROGRAM_VERSION` set to the app's bundle version) names the terminal for
  env-trusting tools, while `TERM=xterm-ghostty` stays the Ghostty-capability
  signal (ADR-0011 follow-up). Process-tree walkers like fastfetch still see the
  `amx` daemon's process name; fixing that display requires an upstream
  fastfetch mapping, not env changes. Background `amx` sessions spawned before
  an identity change keep their original env until the session itself is
  recreated — a live process's environment can't be rewritten from outside.

The app runtime is initialized with settings-backed terminal appearance after
settings bootstrap, so the first surface spawn uses the same terminal identity
as later runtime updates.

For Claude Code foreground/theme regressions, use the opt-in diagnostic loop in
[`docs/debugging/terminal-color-diagnostics.md`](debugging/terminal-color-diagnostics.md)
before adding another visual fix.

awesoMux also injects a UTF-8 `LC_CTYPE` fallback at spawn so panes don't land in
the C locale (where typed emoji echo as `<0001f973>` placeholders). The why, the
probes, and the locale precedence are in
[`docs/debugging/emoji-input-echo-iswprint.md`](debugging/emoji-input-echo-iswprint.md).

## Current Linker Finding

Directly adding `GhosttyKit.xcframework` as a SwiftPM `binaryTarget` compiles
the C module but fails the final app link because the generated static archive
still expects transitive symbols from Ghostty's bundled dependencies, including
ImGui, Sentry, libintl, and the C++ runtime.

The current scaffold imports Ghostty's headers through a local SwiftPM
`systemLibrary` target and links the generated archive explicitly with
`-force_load`. Earlier builds forced Apple's classic linker to avoid
Zig-generated archive member alignment failures, but current Ghostty artifacts
link cleanly with the default linker; `ld_classic` is deprecated and should not
be reintroduced unless a new blocker is captured with current linker output.

The app now owns a minimal process-wide Ghostty runtime:

- calls `ghostty_init` once
- creates and finalizes a `ghostty_config_t`
- creates one `ghostty_app_t`
- services Ghostty wakeups with `ghostty_app_tick`

The surface bridge is split into focused app-target files under
`Sources/awesoMux/Views/GhosttySurface/`:

- `GhosttySurfaceRepresentable` embeds an AppKit `NSView` inside SwiftUI
- `GhosttySurfaceContainerView` owns the scroll wrapper and scrollbar sync
- `GhosttySurfaceNSView` stores identity and hosts the native libghostty surface
- `GhosttySurfaceLifecycle` forwards size, backing scale, visibility,
  occlusion, refresh, and diagnostics
- `GhosttySurfaceInputBridge`, `GhosttyInputMapper`, and
  `GhosttySurfaceTextInputClient` wire keyboard, shortcuts, text send,
  IME/preedit, mouse, scroll, and binding actions into libghostty
- `GhosttySurfaceTerminalEvents` updates title/cwd, shell-activity snapshots,
  visible-text fallback sampling, and runtime-event application
- `GhosttySurfaceProcessExitHandler` preserves ADR 0002 process-exit
  close/recycle behavior while discarding native surfaces
- `SurfaceScrollbar`, `TerminalAccessibilityAnnouncer`, and
  `TerminalBackstopBackground` hold pure scrollbar math, VoiceOver announcement
  strings/posting, and terminal background conversion
- per-pane agent runtime environment variables are injected when surfaces are
  created, and `AgentRuntimeEventBridge` watches the matching JSONL event files
  under the active profile's Application Support directory (`awesoMux` for
  installed/production, `awesoMux-dev` for the primary checkout, or
  `awesoMux-dev-<worktree-id>` for a linked worktree) so adapters
  can update `agentKind` / `agentState` without scraping rendered terminal text
- compact terminal surfaces export `AWESOMUX_COMPACT_TERMINAL=1`. The existing
  Floating Panel also keeps its narrower `AWESOMUX_FLOATING_PANEL=1` marker;
  the global Pop-up Terminal does not pretend to be a Floating Panel. awesoMux
  only sets these markers—the user's shell decides what to do with them. For
  example, a zsh startup file can keep fastfetch out of both compact surfaces:

  ```zsh
  [[ -z ${AWESOMUX_COMPACT_TERMINAL:-} ]] && fastfetch
  ```

- each pane receives `AWESOMUX_PROFILE=production|development|development:<id>`
  after inherited values are scrubbed, so profile-aware maintenance commands
  target the app that created the pane
- the Ghostty OSC notification callback treats desktop notifications only as
  ordinary output-attention signals; it does not parse notification title/body
  content as agent runtime events

The bridge still keeps visible-text scraping as a best-effort fallback for
older/unconfigured panes, but interpretation lives in `AwesoMuxCore`
(`VisibleTextAgentStateReducer`) and the sampled payload is not logged.
`CommandExitCache` similarly owns cached exit-code freshness for process-exit
decisions outside the native view.

## Command Surface Policy

The durable decision lives in
[ADR 0020](adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md).
awesoMux loads Ghostty's default config files for terminal-surface behavior,
colors, fonts, and bindings, then layers awesoMux-owned runtime overrides on
top. That does not make Ghostty's app/window/workspace actions a second awesoMux
command surface.

The source of truth for app commands is the SwiftUI/AppKit command layer backed
by `KeyboardShortcutCatalog`, the Workspace/File menus, and the command
palette. `GhosttyRuntime.action(_:,target:action:)` handles libghostty callbacks
that belong to the terminal surface itself: title, cwd, bell/notification,
mouse/link state, URL/document routing, command-finished, progress, scrollbar,
selection, and search state. Known Ghostty application actions emitted from a
user `keybind` such as new tab/window, split management, goto/resize split,
fullscreen, quit, open/reload config, and related window chrome commands are
claimed and ignored by `shouldClaimIgnoredGhosttyApplicationAction(_:)` so they
do not route through `SessionStore` or create a parallel shortcut source of
truth.

The secure-input callback is handled through a pane-scoped coordinator that
balances macOS secure event input across focused surfaces and clears requests
when surfaces are discarded. Other terminal/system callbacks such as key
tables, key sequences, readonly state, child-exited state, and prompt-title
state remain unclaimed until awesoMux implements explicit bridge behavior for
them.

`GhosttyRuntime` still detects currently-configured Ghostty key bindings that
collide with awesoMux menu shortcuts and logs a warning. If the product later
decides to route Ghostty application actions into awesoMux commands, record that
as a new decision first and keep `docs/shortcuts.md`,
`KeyboardShortcutCatalog`, and the action callback in sync.

Polished notification presentation, OSC clipboard confirmation, and richer
action routing still need to be implemented before this behaves like a polished
terminal.

Scripted automation of pane *content* — injecting keystrokes and reading
scrollback from agents or a second terminal — is not part of this command
surface at all; it goes through the bundled `amx` CLI. See
[`docs/amx-automation.md`](amx-automation.md).

## Updating The Pin

```sh
cd vendor/ghostty
git fetch --tags
git checkout <new-tag-or-commit>
cd ../..
git add vendor/ghostty
```

After updating, rebuild the XCFramework and run the awesoMux test/build checks.
