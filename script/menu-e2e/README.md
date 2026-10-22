# Local launched-app menu gate

Run this for menu-touching changes, in addition to preflight. This is opt-in,
local macOS tooling; no workflow or paid runner is added. It builds a debug app,
stages it in a fresh artifact directory with a random development bundle/profile,
launches that exact executable, captures `NSApp.mainMenu`, compares an explicitly
supplied baseline, and exhausts its independently owned staging and app process
groups before returning. It never
launches or terminates an installed app or another checkout's staged app.

Only `--stage-menu-e2e` skips optional Icon Composer/`actool` compilation and
omits `CFBundleIconFile`/`CFBundleIconName`, producing a **generic-icon host**.
The full debug executable, command definitions, exporter, localizations, fonts,
other resources, signing and fresh random profile use the existing staging path.
Normal debug, install, release and preflight staging keep their icon behavior.
This host covers structural menu registration/export; it establishes neither
icon asset parity nor native icon acceptance. Baseline acceptance must explicitly
cover this host, including its actual native menu behavior. `build.log` records
the icon omission; retain the Info.plist and resource manifest with the evidence.

The DEBUG-only `--menu-e2e-output PATH` diagnostic is inert without the argument
and an isolated development bundle identity. It refreshes menu validation and
waits for four equal samples after the app is active and File/View/Workspace/Pane
menus exist. It serializes titles, order, separator positions, enabled/hidden
flags, key equivalents, raw modifier masks, item state, and nested submenus.
The export is the actual AppKit tree, not an Accessibility projection.

If readiness expires, the debug host retains a separate
`menu.json.unready.json` diagnostic from the actual menu. Its app log records
activation and root titles. This file is unready evidence: the runner still
fails without `menu.json`, creates no baseline, and never compares or approves
the diagnostic as a regression baseline.

## Capture and review

Use a new absolute output directory outside the checkout each time:

```sh
python3 script/menu-e2e/run.py --capture --output /tmp/awesomux-menu-capture-001
python3 script/menu-e2e/run.py --baseline /path/to/reviewed-baseline.json \
  --output /tmp/awesomux-menu-check-001
```

Run the **entire command** under the machine-wide heavy-work lease:

```sh
heavy-gate python3 script/menu-e2e/run.py --capture \
  --output /tmp/awesomux-menu-capture-001
```

Do not wrap the harness's internal staging command again. Exit 75 means
nothing started; wait for the gate rather than running outside it. The harness
uses existing repository toolchains and staging scripts; arrange prerequisites
before running it. Do not install dependencies or change TCC settings as a side
effect of verification.

`--capture` is **capture-only**, never a regression PASS. Inspect `menu.json`
and `baseline.json` against the app's current source and visible menu before
checking a baseline into a menu change. No future Companion behavior is encoded.
`--baseline` returns 0 only for an exact match, otherwise 1 with `menu.diff`.
An invalid baseline (including JSON `null`, arrays/scalars, missing fields or
malformed nested items) is rejected before staging. The schema follows the Swift
export: string titles/keys, boolean flags, unsigned integer modifier masks,
signed integer state, and recursive child arrays. Empty titles/keys, false flags,
and mixed state `-1` are valid. Mode comes from the CLI option, not JSON contents.
Argument/prerequisite failures are nonzero. There is no baseline update-on-fail.

`report.json` records source HEAD/dirty state, executable hash, bundle identity,
child PID/exit, separate staging/app process-group lifecycle records, verdict,
and coverage gaps. `build.log`, `app.log`, `menu.json`,
`baseline.json`, and a mismatch's `menu.diff` remain inspectable. The run-owned
bundle and profile directories go to Trash; the run-owned defaults domain is
removed. Keep evidence tied to the recorded commit and executable. A dirty run
is evidence for that working tree, not clean-commit proof. Retain the source
manifest/overlay with it.

Cancellation latches TERM/HUP/INT and unwinds after retaining each `Popen` handle;
repeated signals cannot interrupt cleanup. Staging and app groups have separate
sessions. Cleanup sends TERM, allows five seconds, escalates to KILL, reaps the
direct child, and verifies group exhaustion even if its leader exited first.
Only then are fresh directories trashed. The lease stays held if a group cannot
finish exiting; inspect the lifecycle report/logs rather than releasing the lease
or signaling processes by name. This covers descendants retaining the owned
group, not helpers that daemonize into another session.

Skipping optional icon compilation removes the observed `actool` -> escaped
`ibtoold` creation path from this mode. It does not prove that all other native
tools or future descendants stay in the owned groups. Before accepting direct
runner return as the coordinated lease boundary, replay native staging/capture
and interruption with this exact host and verify helper absence and actual
lifetimes. Do not reuse a prior bundle manifest as proof or add automatic global
service cleanup. An unresolved survivor requires the native owner to retain the
lease and paths for coordinator intervention, not return and release it.

## Pending native acceptance

There is no approved observed baseline yet. The source-only repair fixtures use
disposable fake staging/app CLIs; they do not compile Swift, capture native menus,
validate signing/resources, or establish native child cleanup. The prior actual
154-item unready dump came from an inactive app on a locked console; it is not a
baseline. Native capture needs an already usable, unlocked foreground session;
this recipe does not authorize unlocking or changing TCC settings.

The next native-lane owner must run these steps sequentially under the machine-wide
lease:

1. Verify HEAD and the source overlay manifest. Run changed-file Swift formatting
   and full `./script/preflight.sh` directly, preserving its exit status. If source
   changes, refresh the manifest and focused review before using earlier evidence.
2. Capture with `--capture` into a new external artifact directory. Keep raw
   `menu.json`, candidate `baseline.json`, report and logs. Before the staged
   bundle is trashed, retain SHA-256 manifests for its executable, Info.plist,
   resources and bundled helpers (for example by adding a recording step to the
   lane's `trash` wrapper that delegates to the real `trash`). Retain source/script
   hashes, macOS build, architecture and effective language/locale alongside them.
   Verify this mode did not invoke `actool` or create its `ibtoold` helper, and
   record absence of both icon assets and their plist keys in this generic host.
   Never substitute a source-derived expected tree for this observed candidate.
3. Independently inspect the observed candidate against the visible/current menu
   and current command definitions: membership/order, dividers, enablement, hidden
   flags, keys/masks, states and nested/system entries. Record reviewer, OS/language
   scope, explicit acceptance of this generic-icon host, and any evidence
   supporting normalization. Keep the raw candidate even when review finds a
   defect. A same-run self-comparison is not baseline approval.
4. After baseline approval, run `--baseline` with a fresh output directory on the
   agreed OS/language; require `passed`/exit 0. Copy that approved baseline, alter
   one actual item title/separator/key, and require exit 1 with `menu.diff`; preserve
   both results without changing the approved fixture.
5. Cancel staging and capture separately by signaling only the recorded runner
   PID, including repeated TERM/HUP/INT. Retain owned PID/PGID/start identities,
   lifecycle reports, and before/after process evidence showing both groups gone
   before stage/profile trash and wrapper completion. Include real non-icon
   compilation/resource/signing stages, stage failure, and app cancellation;
   establish observed helper absence and no surviving run-owned lifetimes, beyond
   merely absent retained groups. Existing unrelated/shared services are not
   grounds for termination. Keep unrelated app instances/profile data intact.

Capture/compare artifacts, full preflight, formatting, existing suites and native
cancellation are distinct evidence. The structural runner's coverage limits below
still apply; complete the wider native journeys separately.

## Coverage and limits

The baseline covers **only fresh empty-profile launch state**. It includes system
menu entries and records the OS version; compare on the same macOS version and
language. System menu changes and dynamic entries need review, not blind fixture
updates. The app label is fixed to `awesoMux Menu E2E` while its bundle identity
is unique. No user profile is moved aside and no environment defaults are set.

No Accessibility grant is needed for in-process export. The older
`script/smoke-floating-rebind.sh` separately exercises New Workspace, Show Floating
Panel, and Previous Workspace through System Events and checks rebind logs. It
requires existing Accessibility authorization and mutates/restores the checkout's
dev profile; it is not part of this harness. Do not grant permission just to run it.
AX menu trees may omit key equivalents or modifier masks; that evidence alone
cannot claim shortcut coverage.

A captured key equivalent proves menu registration, including a disabled command's
presence. It does not prove physical key dispatch, libghostty fall-through,
command invocation, workspace/sheet/Companion/floating-panel enablement changes,
rendered separators, or VoiceOver output. Those need separate native journeys.
Production view/menu/lifecycle changes belong to the frontend owner.
