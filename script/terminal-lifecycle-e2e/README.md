# Deterministic native terminal lifecycle E2E

## Failure model and implementation plan

The oracle must reject echoed input, input sent to the wrong pane, replaced
shells, dead sibling jobs, a close that bypasses confirmation, a cancelled close
that still kills work, and a reopen that creates a replacement backend. Missing
permissions, a console session, a staged bundle, or unambiguous window/focus
identity block execution. Screenshots are human evidence only; capture errors
block the run. No model dependencies, generated prose matching, screenshot
baselines, or visual AI pass decisions.

Display titles can become the current directory during reattachment, including
between readiness and dispatch. A shared HOME directory must never identify a
pane. Each backend therefore starts in `output/fixtures/panes/ZMX_SESSION`,
outside HOME, and emits that same canonical path as OSC 7 CWD and OSC 2 title.
Registration, challenge, and job receipts must retain the exact backend, shell,
profile, namespace, and CWD binding. AX admission compares that unique path,
resolving filesystem aliases such as `/tmp` and `/private/tmp`; a sibling path
or shared HOME still fails. The native helper rechecks admission immediately
before its single keyboard dispatch, without resetting titles or retrying input.

Use one standalone Python driver, a small native AX/CG helper, and synthetic zsh
startup/foreground-job fixtures. Copy and reidentify an already staged app with
a fresh runtime-profile.sh identity; refuse existing profile paths or defaults.
Use real menu actions and PID-targeted keyboard events only after checking the
owned window and focused terminal title. Match exact challenge response lines
computed in the fixture, plus shell PID/backend identities and a live heartbeat.
Poll bounded monotonic deadlines; never retry an action to obtain a pass. Retain
report.json, timeline, fixture receipts, history and window-only PNGs. Cleanup
only the copied app PID, its isolated daemon namespace, and disposable paths. The copied app bundle is trashed after successful cleanup;
the helper, reports, fixtures, and evidence remain.

## Contracts and maintenance

| ID | Intended user outcome | Commands and source areas |
| --- | --- | --- |
| TL01 | Two usable panes in one real window | File > New Workspace; Pane > Split Right; `App/AwesoMuxApp.swift`, `Views/TerminalSplitLayoutView.swift`, `Services/AmxBackend.swift` |
| TL02 | Focus Pane 1/2 executes each challenge only in its intended pane; any sibling execution fails | Pane > Focus Pane 1/2; `Services/KeyboardShortcutCatalog.swift`, `Views/GhosttySurface/GhosttySurfaceInputBridge.swift`, `Views/GhosttySurface/GhosttySurfaceNSView.swift` |
| TL03 | Exiting one shell removes that pane while sibling shell/job survives | native typed `exit`; `Views/GhosttySurface/GhosttySurfaceProcessExitHandler.swift`, `AwesoMuxCore/Stores/SessionStore.swift`, `Services/AmxBackend.swift` |
| TL04 | Cancel busy-close preserves the same running controlled job | Pane > Close Workspace (last pane), Cancel; `App/AwesoMuxApp.swift`, `Services/DestructivePaneActionConfirmationPolicy.swift` |
| TL05 | Soft-close/reopen restores a usable same persistent terminal | Workspace > Close Workspace / Reopen Closed Workspace; `App/AwesoMuxApp.swift`, `AwesoMuxCore/Models/SessionSnapshot.swift`, `Services/AmxBackend.swift` |

Paths in the table are relative to `Sources/awesoMux/` except those beginning
`AwesoMuxCore/`, which are relative to `Sources/`. The current documented
contract is in `docs/shortcuts.md`, `docs/amx-automation.md`, and ADR-0002.
Changes in these areas require reviewing this table. If the intended contract
changes, deliberately update the expected outcome and rerun with fresh,
inspectable evidence. Add a scenario for new user-facing behavior only when
this flow misses a distinct meaningful failure; avoid permutation growth.

Reports record exact source HEAD, dirty diff SHA-256, and hashes of all harness
files and relevant source/docs. The existing `source.files` mapping retains
vendor HEADs; `source.submodules` maps each vendor path to `head`,
`stagedDiffSHA256`, `unstagedDiffSHA256`, and `untrackedSHA256`. These capture
tracked staged/unstaged binary diffs and a sorted list of nonignored untracked
paths, file kinds, and content hashes. Symlinks hash their link text without
reading targets; ignored build outputs are excluded. Neither current vendor has
nested Git submodules; adding one requires extending capture before the runner
will accept it. Older reports without this fingerprint are stale.
`--check-freshness REPORT` compares those values
against the current checkout without launching the app. A mismatch makes the
old evidence stale, not a new lifecycle failure. Binary hashes identify what
actually ran; staging provenance must be reviewed separately if the bundle was
built before the recorded source state.

## Run

From a linked worktree, stage separately (the runner never builds):

```sh
./script/build_and_run.sh --stage-local-api-e2e
python3 script/terminal-lifecycle-e2e/run.py --check-prerequisites --output /tmp/tl-prerequisites
python3 script/terminal-lifecycle-e2e/run.py --output /tmp/tl-run
python3 script/terminal-lifecycle-e2e/run.py --check-freshness /tmp/tl-run/report.json
```

Use a new output directory each time. Requires macOS GUI login, Xcode `swiftc`,
Python 3, `trash`, an already staged `dist/awesoMux.app`, and existing Accessibility
and Screen Recording grants for the invoking host. The helper probes permission
without requesting it. Prerequisites compile/probe the helper and inspect paths;
they do not launch/drive the app, write defaults, or create a profile. Their
report is `blocked` with `mode: prerequisites` even when ready: this is not E2E.
Exit codes: 0 lifecycle pass / prerequisites ready / evidence fresh; 1 failure or
stale evidence; 2 blocked prerequisite. SIGINT/SIGTERM produce a failure report
and attempt scoped cleanup. Killing the runner with SIGKILL cannot run cleanup;
inspect the retained report/profile identities before manual recovery.

The interactive console must be unlocked, on-console, logged in, and owned by
the invoking UID (both the session UID and `/dev/console` owner). Unlock the Mac
manually before running. `consoleState` records the actual booleans, lock-key
presence/type/raw value, UID checks, and errors. The runner checks this before
every native operation; the helper checks again before window access, activation,
menu/Cancel presses, and each keyboard event pair. A mid-run lock blocks further
input and still attempts scoped process/namespace cleanup. No permission prompt,
unlock attempt, or lock-screen interaction is performed.

The SDK's `CoreGraphics/CGSession.h` documents `kCGSessionOnConsoleKey`,
`kCGSessionLoginDoneKey`, and `kCGSessionUserIDKey`; a non-nil
`CGSessionCopyCurrentDictionary()` only establishes a Quartz GUI session.
`CGSSessionScreenIsLocked` is an observed system dictionary key, not a documented
SDK constant. Explicit boolean/numeric 0 means unlocked and 1 means locked.
On this host the key changed from 1 while locked to absent after a confirmed
manual unlock. The harness accepts absence as unlocked only within a logged-in,
on-console session whose session and console UIDs match the invoking user.
`lockSignal` records whether the result came from an explicit value or this
observed absence convention. Missing session data and malformed present lock
values block. This convention is observed macOS behavior, not a documented API
guarantee; recheck it when host behavior changes. A prerequisite or readiness run
provides no journey pass.

The runner launches the copied `.app` through LaunchServices using
`NSWorkspace.OpenConfiguration`, a new application instance, explicit arguments,
and the fixture environment. It verifies the returned PID, executable path,
bundle identity, and process start before native operations. Cleanup verifies
executable and process start again before both TERM and KILL; lost launch replies
recover only the exclusive copied executable. An unresolved launch retains state
and fails cleanup rather than removing paths a delayed app could still use.
The signed copy must pass `codesign --verify --deep --strict` before launch.
Executable comparisons resolve filesystem symlinks consistently; raw observed
paths remain in launch/process evidence. Before each signal, one `ps` observation
provides status, start, and executable together. Disappearance/zombie is absent;
a live canonical executable or start mismatch refuses the signal. Every process
birth read, including launch, observations, and recovery, uses `TZ=UTC` and
`LC_ALL=C` so inherited timezone/locale cannot alter the comparison.
Recovery retains its exact executable/start observation and the subsequent PID
observation. A process already absent or zombie needs no signal, while its owned
namespace still receives cleanup. A matching-birth process marked `E` (exiting)
may have its executable replaced by `(awesoMux)` in `ps`; it receives no further
signals. Cleanup waits up to five seconds for actual absence/zombie before
touching its namespace. The exiting observation and any timeout remain evidence;
a different live executable or birth still fails identity validation.

Focus challenges retain the intended shell PID and exact output-line proof.
Receipts and atomic temporary files are keyed by both nonce and executing backend
session; a sibling cannot overwrite intended evidence. Every challenge rejects
any sibling receipt/temporary file or the sibling's own computed response (as
well as the intended response) in sibling history. All earlier challenges are
audited again at journey completion and their retained receipts after backend
termination, catching delayed sibling execution without sleeps or redispatch.

A content-window readiness failure retains `window-readiness-diagnostic.json`,
including AX errors, roles/subroles, owner PIDs, CF types, equality with the app
root, and the exact PID's CG inventory. The retained helper also supports
`native diagnose PID` without requiring a valid window. Diagnostics never relax
input admission: an actual AXWindow with the exact owner PID, standard subrole,
and unique CG correspondence is still required.
Owned modal diagnostics include descendant text/buttons with per-element PID
checks and traversal limits. Modal PNG evidence permits nonzero CG layers while
still requiring the exact owned AXDialog, unique bounds match, and valid main
window. The first backend wait stops on an unexpected modal without pressing it.
Initial readiness polls missing windows and zero correspondence matches within
the existing deadline; ambiguous matches fail immediately. Later failures retain
`failure-diagnostic.json` when the owned app can still be inspected.

Activation uses `NSRunningApplication.activate(options:)` once, recording its
return separately. It must produce both a frontmost owned app and an AX focused
window equal to the exact validated content window before commands proceed.
The extra AXRaise action is not required: an unlocked run accepted activation
but returned `attributeUnsupported` for AXRaise. Admission verifies the actual
focus outcome instead of requiring that unsupported action.

App stdout/stderr are not redirected: `NSWorkspace.OpenConfiguration` has no
stdout/stderr handles. `launch-request.json`, `launch-receipt.json`, `steps.jsonl`,
fixture receipts, and captured backend histories provide inspectable evidence.
There is no `app.log` claim. For extra diagnostics, a reviewer can collect macOS
unified logs filtered to the recorded app PID; those logs are separate evidence
and may not include stdout/stderr. Raw executable launch is never a fallback.

The app and helper children receive disposable `HOME` and `CFFIXED_USER_HOME`
under `output/fixtures/home`, `/bin/zsh`, synthetic ZDOTDIR and XDG config. The
runner's own home/environment stays unchanged. Before profile creation, the
compiled native helper runs in that exact child environment and must resolve
`FileManager.homeDirectoryForCurrentUser`, `NSHomeDirectory()`, and Application
Support to the exact canonical fixture paths (resolving system `/tmp` symlinks). A
mismatch blocks the run. The report retains expected, raw, and canonical
resolved paths; shell receipts also verify the delivered home
overrides. `CFFIXED_USER_HOME` is a Foundation override, not a general sandbox:
this proves the current path resolution seam, and must be rechecked on every run
and reviewed when path APIs change. Unique bundle/defaults and daemon socket
namespaces remain required. No real Ghostty config is read or modified.

libghostty's macOS command path uses `/usr/bin/login -flp`, which resets HOME to
the account home before zmx inherits it (`vendor/ghostty/src/termio/exec.zig`,
`vendor/zmx/src/daemonize.zig`, and local `login(1)`). The fixture `.zshenv`
validates its synthetic ZDOTDIR, fixture root, and previously verified
CFFIXED_USER_HOME, records the incoming HOME, then restores synthetic HOME before
later startup files and fixture commands. Receipts retain the incoming/restored
HOME and startup/current ZDOTDIR; the synthetic HOME assertion remains strict.
This does not hide earlier platform behavior: libghostty/login can consult the
account `.hushlogin`; this harness is not a filesystem sandbox. App config paths
are resolved and checked before that login step; user shell startup uses the
synthetic ZDOTDIR, and system startup files remain platform-owned.

A minimal synthetic app config enables the command bridge and busy-close
confirmation, mutes notification channels, and skips the first-run tour. Muting
uses the existing config setting to prevent unrelated notification onboarding;
no notification permission is requested or granted. System zsh startup remains
platform-owned; fixture registration verifies shell/backend environment before
input. English menus are required. No agent integrations are installed or
invoked. A failed cleanup keeps the isolated paths and bundle for inspection and
changes the result to fail.

Screenshots: two panes ready, busy-close modal, reopened usable terminal, and
last failure when an owned window is available. They are captured by exact owner
PID + CG window ID, decoded as PNG, and never use a desktop fallback. This manual
gate does not imply full preflight, VoiceOver, device, or hosted CI acceptance.
