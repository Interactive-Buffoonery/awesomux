# Ghostty Integration

awesoMux vendors Ghostty as a pinned git submodule:

- Path: `vendor/ghostty`
- Upstream: `https://github.com/ghostty-org/ghostty.git`
- Current pin: `cf0ab14aed55315a53de668bc1bbcf4a13ce0ddd` (untagged `origin/main`, post-`v1.4.0`)
- License: MIT

> This pin includes upstream's [Kitty history cleanup](https://github.com/ghostty-org/ghostty/pull/14832)
> and [color-scheme report fix](https://github.com/ghostty-org/ghostty/pull/14834).
> awesoMux now uses upstream's history cleanup and retains its no-scrollback
> resize hook and regression checks. Color-scheme reports are sent directly
> during configuration changes, avoiding a write back to the I/O thread's own
> mailbox. This pin also fixes stale scrollback pins, cursor style and hyperlinks
> after history pruning, and malformed UTF-8 configuration handling. Shell
> integration escapes directory names before writing terminal control sequences.
> This revision adds DEC column operations, corrects VT formatter wrapping,
> and rejects empty prefixed commands. It also updates embedded tmux control
> handling and z2d rasterization to 0.13.2.
> The public embedded C header and bundled Ghostty license are unchanged.
>
> Pinned past `v1.3.1` to pick up upstream resize/reflow fixes (notably
> `#12653` "preserve shell prompts on resize") and the VT throughput work
> (`#13209`/`#13220`/`#13226` — parser-bound IO plus print/CSI fast paths).
> INT-732 measured a ~40x end-to-end win for sustained plain-ASCII output in
> a single dev session (150MB `cat`: 77–235s before, ~1.8s after; UTF-8-heavy
> content gains far less — see PR #551 for methodology and caveats).
>
> The pin includes upstream's scrollback compression series. Idle offscreen
> pages are LZ4-compressed (`scrollback-compression`, upstream default on),
> cutting physical memory for cold history without changing how much history is
> retained. Note the tradeoff: reads that touch a compressed page decompress it
> synchronously and leave it resident — see the ceiling notes in
> `Sources/AwesoMuxConfig/GhosttyRuntimeDefaults.swift`.
>
> The pin requires Zig 0.17 and retains the static-link post-processor. Its current
> archive post-processor leaves compiler-rt's `_memset` private-external, which
> ld64 still rejects beside Ghostty's own override; our build script finishes
> that one-symbol localization before publishing the archive. The zmx and
> Ghostty builds select their declared Zig toolchains independently.

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

## Delimited Markdown paths with spaces

awesoMux adds detection for Markdown paths containing literal spaces when
surrounded by matching parentheses, single or double quotes, or backticks.
For example, `(support case/reply draft.md)` opens the complete relative path
against the pane's working directory. Unquoted text keeps upstream detection;
internal quotes and parentheses in filenames are outside this extension's scope.

`native/ghostty/link-paths.zig` adds this branch ahead of the upstream detector.
The source preparation script installs it only in the generated build copy,
with a checked config insertion point and the existing artifact fingerprint.
The pinned submodule is unchanged. The library build runs the
`awesomux-link-paths` native regression tests before publishing artifacts.
Existing document validation and remote-read authorization still own opens.

The same native detector recognizes complete bare `.md`/`.markdown` filenames
(case insensitive), optionally followed by `:line[:column]`. Surrounding
whitespace, quotes, backticks, commas, semicolons, brackets, braces, angle
brackets and pipes are excluded from the match. Adjacent path/URL characters,
email addresses and extra extensions do not produce a bare filename suffix
match; upstream URL and path detection remains unchanged. A standalone
`example.md` is inherently ambiguous with a domain and is treated as a filename
candidate. Ghostty owns the exact Cmd-hover underline, cursor and clearing,
including existing OSC 8 precedence; no app overlay or polling is involved.

This also enables native hover in local panes. Opens still pass through existing
local working-directory resolution, Markdown validation and existence checks.
Remote opens still require the existing origin checks and per-read authorization;
matching and hovering grant no file access. User-configured link rules retain
their existing behavior.


## Direct SSH directory suggestions

The generated source adds `awesomux_remote_pwd` to the application surface
mailbox before `termio/stream_handler.zig` rejects a nonlocal OSC 7 URI. A fixed
2,048-byte report rejects overflow, invalid UTF-8 and embedded NUL in full. The
normal Ghostty parser, local-host check and stored terminal pwd are unchanged.

The main-thread surface handler delivers this advisory event through the existing
PWD action with the reserved `awesomux:remote-osc7:` prefix. Absolute local PWD
paths cannot collide. awesoMux consumes the envelope synchronously before normal
cwd updates. A narrow C setter publishes a per-surface atomic generation, copied
by the reader into each report before enqueueing and carried in the envelope.
Swift advances it on observed connection/origin invalidation and checks it before
acceptance, including when the store changes ahead of the view update. Fresh
reports on a surviving surface use the new generation; queued old reports cannot
cross the barrier. Counter exhaustion permanently disables this view's reports
instead of reusing a generation. No reader-thread Swift callback is introduced.
Managed panes use
qualified raw metadata or daemon metadata for remote cwd; ordinary native PWD
still updates local panes through the existing path.

Strict file URI validation rejects local hosts, credentials, ports, query,
fragment, malformed escapes and unsafe characters. The host must match the
observed title host or, when absent, the declared target, with only short-name
and `.local` equivalence. This is a runtime-only editable directory suggestion,
not authorization, an execution-plan change or Remote File Context.

One report may await initial title recognition for at most one second. It is
bound to the session, pane, terminal, native surface incarnation, execution plan
and connectivity epoch. Initial title recognition preserves pending evidence;
a managed first title confirming the declared host also preserves accepted cwd.
Local reports, established title/host transitions, connection changes,
recycle, exit and disposal discard pending evidence. No alias/DNS guessing is
performed; hosts that do not match need an explicit user-selected base directory.
Native and daemon reports use the same URI and host qualification. Spaces in
reported file URIs must be percent-encoded; malformed or repaired encodings are
rejected by both sources. The daemon inventory keeps its separate below-256-byte
admission limit.

All native fragments and regression cases participate in the source fingerprint.
`script/verify_remote_pwd_injection.py --vendor /path/to/pinned/ghostty` verifies
exact insertion counts and preservation of upstream source without compiling.
The native build also runs the `awesomux-remote-pwd` bounded-copy regressions.

## Command completion status fidelity

The generated source preserves unknown OSC 133 command status. In the pinned
upstream stream handler, an omitted/malformed exit code becomes zero and a value
outside 0–255 becomes one. `prepare_ghostty_source.py` replaces only that exact
conversion block with `native/ghostty/command-status.zig`, failing if the anchor
is absent or duplicated. Vendor source and its pin remain unchanged.

The helper retains `?u8`: explicit zero is success, 1–255 remain known exits,
and absent, malformed, negative or oversized values remain `null`. The existing
surface mailbox and completion action preserve that optional status; the C
export maps `null` to `-1`. The Swift exit cache clears prior evidence when an
unknown completion arrives, so it cannot later signal a failed process close
or sibling-pane alert. Agent completion detection already ignores negative
status; only explicit zero clears a stale execution error.

The helper, regression fragment and preparation script participate in the native
artifact fingerprint. Ordinary `build_ghostty_xcframework.sh` rebuilds execute
the `awesomux-command-status` native regression before publishing artifacts.
The test parses OSC 133 C followed by statusless D, explicit D;0/D;1/D;7/D;255,
and invalid D values, passes the actual helper result through the surface
message payload and completion C export, and checks status and duration. It
does not drive a real terminal stream, surface timer, mailbox delivery, or Swift
callback, so live OSC133/PTY behavior remains a separate runtime check.

Source-only verification (no compilation or vendor writes):

```sh
python3 script/verify_command_status_injection.py --vendor vendor/ghostty
```

Focused native regression, with `AWESOMUX_ZIG` set to the compatible Zig binary
used by the standard native build:

```sh
process-gate -- sh -c '
  set -eu
  generated_source=$(python3 script/prepare_ghostty_source.py)
  cd "$generated_source"
  "$AWESOMUX_ZIG" build test -Dapp-runtime=none -Demit-macos-app=false \
    -Dtest-filter=awesomux-command-status --summary all
'
```

The existing `CommandBridgeRuntimeDeathHealViewTests` command-completion case
also covers known success and unknown status replacing a cached failure. Run
that Swift regression through the gate after refreshing native artifacts.

## Bounded Show Scrollback read

Whole-history consumers use the awesoMux-only `awesomux_surface_read_scrollback`
extension declared in `Sources/GhosttyKit/AwesoMuxGhostty.h`. The ordinary
Ghostty text APIs remain unchanged for other callers.

`script/prepare_ghostty_source.py` creates a generated clone of the pinned
source in disposable build scratch, adds the checked-in
`native/ghostty/` extension, and registers its native regression tests.
The build removes its scratch directory on exit, so source copies do not
accumulate in the artifact cache. It never edits `vendor/ghostty` or changes
its pin. The extension is
compiled with Ghostty so it can hold the renderer mutex across both size
validation and formatting, using the current terminal rather than asynchronous
scrollbar callbacks.

Admission limits are 8,192 rows, 262,144 cells, and 16 MiB of terminal page
backing storage. Page metadata is checked without decompressing history.
Accepted history is formatted into a caller-owned 4 MiB fixed buffer. A write
that exceeds that buffer rejects the entire dump; partial text is discarded.
The page budget also bounds the decompression work for an accepted read.
These bounds control extraction work and storage; they are not a wall-clock
latency guarantee under arbitrary CPU or renderer-lock contention.

The extension's content fingerprint is part of artifact validation and CI
cache keys. An older library without this API cannot satisfy the build.
The library build runs the native `awesomux-scrollback` tests before publishing
artifacts. Ghostty updates must pass those tests and the extension injection
check; see [ADR 0034](adr/0034-native-scrollback-safety-boundary.md).

Extraction runs on a worker. The main-actor coordinator keeps the native surface
and its app alive until that worker finishes, defers surface frees and runtime
reload, and rejects overlapping reads on the same surface. UI completion checks
the request and surface identity again so dismissed or replaced panes cannot
receive stale results. Cancellation does not interrupt a native read.

The whole-history API still succeeds only for complete history within these
limits; local-agent API budgets and consent are unchanged. Show Scrollback uses
the separate `awesomux_surface_read_recent_scrollback` entry point. It starts at
the last page, admits a suffix using the same row/cell/backing limits without
restoring excluded older pages, and formats directly between page pins under
the same lock. Even a partially selected page is charged at its full backing
size. Its caller-owned text buffer is 256 KiB to bound native text layout.

If the fixed writer overflows, the failed prefix is discarded and the read
retries half as many of the newest physical rows. Retries remain within the
admitted suffix, at most one plus floor(log2(admitted rows)) attempts. This
preserves complete terminal cells/graphemes and retains the newest row rather
than returning an older prefix. An oversized single row or newest page still
rejects safely. A suffix can begin midway through a soft-wrapped logical line;
the omission notice covers that missing beginning as well as older lines.

Status 0 means all output fit; status 2 explicitly means older output was
omitted; status 1 rejects without publishing any bytes. The sheet displays an
omission notice separately from its immutable text view. Copy uses that exact
text view payload, excluding the notice, even if the live terminal changes.
Request/surface identity checks and the existing native ownership coordinator
also apply to recent reads. Cancellation discards the UI result; a native lock
wait/read already in progress finishes before surface destruction or reload.
No terminal contents are persisted, logged, or sent by this viewer.

See [recent scrollback verification](verification/recent-scrollback.md) for the
64 MB, Unicode, compressed-history, cancellation, copy and native UI recipe.

## Kitty images when clearing scrollback

The generated source removes image placements anchored in erased history before
Ghostty moves their tracked pins. Without this cleanup, `clear` at a prompt can
move an image into history and then relocate it onto the active screen when
scrollback is erased (ED3), overlapping the next image. Active-screen placements
and placements in retained history are preserved; relative children of removed
placements are cleaned up through upstream orphan handling. Image data remains
available for later placements under the existing storage limit.

Ghostty now provides history-image cleanup in `Screen.eraseHistory` and image
storage. Generated source routes no-scrollback resize through that same cleanup.
The upstream call, storage function and resize anchors fail closed on missing or
duplicate matches. The resize hook and regression fragments participate in
artifact fingerprinting. Native builds
run `awesomux-kitty-clear` renderer and storage regressions, including partial
history erasure and histories spanning multiple pages. No-scrollback resize
uses the same cleanup before discarding history, including on the alternate
screen; its regression covers both primary and alternate screens.

Source-only verification:

```sh
python3 script/verify_kitty_clear_injection.py --vendor vendor/ghostty
```

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

## Manual SSH terminal compatibility

Generated resources include independently written zsh and fish `ssh` wrappers.
They install at the first prompt after user startup, preserving existing SSH
aliases/functions and executable lookup through `PATH`. When the inherited
terminal is `xterm-ghostty`, the wrapper supplies `TERM=xterm-256color` only to
the SSH process; local TERM and other terminal selections are unchanged.
This also means hosts with working Ghostty terminfo receive the fallback.
`command ssh`, absolute executable paths, custom aliases/functions, unsupported
shells, and disabled shell integration bypass it. Existing persistent shells
need recreation. No remote probes or installations occur.

The scripts are fingerprinted and staged through `prepare_ghostty_source.py`;
the vendored source and pin stay unchanged. Unsupported upstream helpers that
require the standalone `ghostty +ssh` executable remain disabled.
See [`../script/ssh-terminal-e2e/README.md`](../script/ssh-terminal-e2e/README.md)
for real OpenSSH PTY verification and its coverage limits.

## SSH mouse recovery in local zsh

Local bridged zsh panes install awesoMux's independently written
`native/shell-integration/ssh-mouse-recovery.zsh` through the generated startup
resources. A one-shot environment marker enables the hook and is consumed before
child programs or nested shells start. The generated-source fingerprint includes
the hook, so cached resources cannot silently omit it. Vendor files and pins stay
unchanged.

After a directly entered `ssh` or `/usr/bin/ssh` command exits, the shell emits
only mouse tracking and encoding disables before its next prompt. This restores
both amx's VT parser and the attached Ghostty terminal in PTY output order;
there is no asynchronous reset that could reach a newly started TUI. awesoMux
local shell prompts use normal terminal selection. Mouse capture remains owned
by foreground terminal programs while they run. A suspended direct SSH job
retains its mouse modes through `fg`; cleanup happens after the recorded job
actually exits. The record includes its process ID so an unrelated job reusing
the same job number cannot keep the old recovery pending. A stopped SSH TUI
continues to own mouse modes at the local prompt, so normal prompt selection is
restored when it exits, rather than while it is suspended.

Compound commands, user-defined shell functions named `ssh`, and wrappers are outside this
hook's scope. A command such as
`ssh host; local-tui` keeps its existing terminal behavior. Bash and fish are unchanged. Existing persistent zsh shells
need to be recreated once to load the updated startup resources; reattaching a
shell that already loaded the hook retains it. Startup files that replace the
shell's hook arrays can disable integration, including this recovery hook.

The disposable PTY check uses a chosen SSH host and produces inspectable logs:

```sh
python3 script/test-ssh-mouse-recovery.py \
  --amx .build/amx/amx \
  --integration .build/ghostty/share/ghostty/shell-integration/zsh \
  --host example-host \
  --output /tmp/amx-mouse-proof
```

It covers SSH exit, live local and remote TUIs, a compound SSH/TUI command,
next-command ordering, a nested shell, reattachment, an ordinary command,
nonzero command status through later shell hooks, absolute SSH with a shell
function present, suspension/resumption, and unrelated stopped-job reuse.
The output directory contains a readable `report.txt` PASS summary and one
transcript per case. Inspect both when reviewing a run. It verifies amx and the
emitted attach bytes; running-app mouse movement remains a separate manual check.

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
- `SurfaceScrollbar` and `TerminalAccessibilityAnnouncer` hold pure scrollbar
  math and VoiceOver announcement strings/posting
- terminal placeholder layers use the runtime’s finalized config background,
  matching the selected Ghostty, bundled, or custom color before native rendering
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

### Patching a vendored dependency for local diagnostics

If you ever need to add temporary diagnostic instrumentation to a vendored
Zig dependency (e.g. libxev) to debug it in place, three separate traps stack
on top of each other — hit all three in one evening (2026-07-22, see
`Interactive-Buffoonery/awesomux#176`):

1. **Wrong cache location.** `script/build_ghostty_xcframework.sh` fetches
   dependencies into a **project-local** `ZIG_GLOBAL_CACHE_DIR`
   (`.build/ghostty/zig-global-cache-<mode>/p/<pkg>-<hash>/`), not the default
   `~/.cache/zig/p/`. Patch the file under `.build/ghostty/...`, not the user
   global cache — the latter is never read by this build.
2. **The build script wipes that exact directory on every invocation**
   (`rm -rf "$AWESOMUX_ZIG_CACHE_DIR" "$AWESOMUX_ZIG_GLOBAL_CACHE_DIR"`
   unconditionally). Re-running the script to pick up a patch destroys the
   patch first. To test a patch: edit the real
   `script/build_ghostty_xcframework.sh` in place to skip clearing
   `$AWESOMUX_ZIG_GLOBAL_CACHE_DIR` for that one run, build, then
   `git checkout -- script/build_ghostty_xcframework.sh` immediately after
   (confirm clean via `git status --short`). Check `git diff` on the script
   *before* the temporary edit — `git checkout --` discards ALL local edits
   to the file, including unrelated ones you had in flight; stash or save
   those first. Do not copy the script elsewhere
   to edit it — its `ROOT_DIR` is computed relative to its own location and
   breaks if run from a different path.
3. **SwiftPM will not relink against the rebuilt archive.** `Package.swift`
   links `libghostty-fat.a` via a raw path string inside `GhosttyKitLinker`'s
   `unsafeFlags` (`-Xlinker -force_load -Xlinker <path>`, matching the
   `-force_load` link strategy described above). SwiftPM/llbuild treats that
   as opaque command-line text and never stats the archive — the link step
   looks "up to date" no matter how many times the archive's *content*
   changes, so `swift build`/`./script/build_and_run.sh` reports "Build
   complete!" without actually relinking. Force it by deleting the stale
   output before rebuilding:

   ```bash
   rm .build/arm64-apple-macosx/release/awesoMux   # and/or debug/, matching your build config
   ./script/build_and_run.sh build
   ```

   Verify with `strings dist/awesoMux.app/Contents/MacOS/awesoMux | grep -q
   '<your diagnostic string>'` before trusting a rebuild — this is systemic
   and will recur on every future Ghostty/libxev rebuild until the target
   moves to a real `binaryTarget` (which SwiftPM does checksum) or the build
   script gains a staleness guard for the linked archive.

## Command Surface Policy

The durable decision lives in
[ADR 0020](adr/0020-ghostty-app-actions-are-not-an-awesomux-command-surface.md).
awesoMux loads Ghostty's default config files for terminal-surface behavior,
colors, fonts, and bindings, then layers awesoMux-owned runtime overrides on
top. That does not make Ghostty's app/window/workspace actions a second awesoMux
command surface.

The source of truth for app commands is the SwiftUI/AppKit command layer backed
by `KeyboardShortcutCatalog`, the File/View/Workspace/Pane menus, and the
command palette. `GhosttyRuntime.action(_:,target:action:)` handles libghostty callbacks
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
