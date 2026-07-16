# 0011 — Persistent session daemon via a command-bridge (zmx behind an `amx` seam)

- **Status:** Proposed
- **Date:** 2026-06-23
- **Deciders:** eD, Sarah

## Context

awesoMux does **metadata-restore, not session-restore**. `SessionPersistence` →
`session-state.json` (schema v3) persists the *shape* of the workspace — groups,
the split-layout tree, titles, cwd, `agentKind` — and on relaunch rebuilds the
tree but **spawns brand-new shells** (see [ADR-0005](0005-session-persistence-json-snapshot.md)).
Structurally lost on quit/crash: **scrollback**, **running processes** (a live
Claude/Codex session, a long build, an SSH connection), and **in-flight terminal
state** (cursor, alt-screen apps, env mutations). Closing that gap is the robust
backend for the aspirational half of INT-282 and is a load-bearing leg of the
product's differentiation thesis.

[zmx](https://github.com/neurosnap/zmx) (MIT, Zig, built on `libghostty-vt`) is a
tmux-like attach/detach session manager stripped to just persistence — one daemon
per session, the daemon owns the PTY, `libghostty-vt` keeps terminal state +
scrollback, and a reattaching client gets a snapshot. MIT keeps it clean against
our GPL/source-read firewall, and it is from the same ghostty family we already
build.

**Make-or-break constraint (verified):** `ghostty_surface_config_s`
(`vendor/ghostty/include/ghostty.h`) exposes `working_directory`, `command`,
`env_vars`, `initial_input`, `wait_after_command` — **no field attaches an
existing PTY/fd**. `ghostty_surface_new()` always forks+execs its own child. So
"awesoMux surface attaches to the daemon's socket directly" is impossible through
the public libghostty API. The only architecture that works with **zero
libghostty changes** is a **command-bridge**: the surface's child is a thin
attach-client.

```
ghostty surface ──spawns──▶ amx attach <id> ──unix socket──▶ daemon ──owns──▶ real shell + agent
 (full emulator,            (thin client,                    (libghostty-vt keeps
  renders normally)          proxies stdio)                   state + scrollback)
```

App quit/crash kills the attach client; the daemon and real shell keep running.
Relaunch respawns each pane with `command = amx attach <id>`; the daemon replays
its snapshot and scrollback + live process return.

A de-risk spike (2026-06-23, branch `spike/int-561-derisk`, env-gated throwaway
seams) validated the approach end-to-end and surfaced where it really lives or
dies. A cross-model adversarial review (Codex, gpt-5.5) pressure-tested the
conclusions; its central finding — *the bridge can preserve shells while quietly
breaking the product if terminal semantics don't survive the nested VT* — drove
the decision below. See **Spike findings** for the evidence.

## Decision

1. **Adopt the command-bridge.** Each terminal pane's surface runs an attach
   client instead of a login shell. App lifecycle owns only the client; the
   daemon owns the durable session. Validated: daemon survives app kill with the
   live process and scrollback intact; relaunch reattaches to the same daemon and
   the same process pid.

2. **Vendor zmx first, behind an awesoMux-owned `amx` command.** The Swift bridge
   spawns `amx attach <id>` — never `zmx` directly. `amx` is a thin pass-through
   to zmx for session ops today (`attach`/`list`/`wait`/`history`/`kill`) and the
   namespace for awesoMux-specific subcommands later (the pattern cmux uses with
   its `cmux` command). This is the protocol boundary that lets a native Swift
   daemon replace zmx later without touching app code.

3. **`amx` is the out-of-band semantic channel, not just branding — this is the
   spike's key architectural finding.** The bridge transports the *live visible
   terminal* faithfully, but awesoMux's *semantic chrome* — cwd, prompt/idle
   state, and agent state — must be sourced **out-of-band through `amx`**, not
   scraped from forwarded OSC, because:
   - **Agent events already use an out-of-band file side-channel**
     (`$AWESOMUX_AGENT_EVENT_FILE`, kqueue/JSONL, keyed by pane UUID) — immune to
     nested-VT loss; the spike confirmed the required env propagates through the
     bridge.
   - **zmx already exposes cwd out-of-band** (`getcwd`/IPC, surfaced as
     `start_dir`); it does not forward OSC 7 by design, so awesoMux reads cwd from
     `amx`, not the PTY stream.
   - **zmx's reattach payload is a reconstructed snapshot**
     (`serializeTerminalState`), which carries grid + cursor + SGR + a rewritten
     OSC 133;A prompt marker but **no OSC 7/title/agent state** — so any chrome
     scraped from forwarded OSC would vanish on every relaunch anyway.

   This unifies eD's `amx` idea, Codex's "design a `PersistentTerminalBackend`
   around capabilities" recommendation, and the file-side-channel pattern awesoMux
   already ships for agents.

4. **Keep persisted records backend-neutral.** Pane records store an awesoMux
   `TerminalSessionID` (an awesoMux concept, distinct from pane UUID / UI tab
   identity / daemon socket name, which have different lifetimes). zmx-specific
   identifiers, wait-states, history assumptions, and error strings live in a
   backend-private metadata blob. This is what makes the zmx→native reversal path
   real rather than a future migration project.

5. **Preserve OSC 133 live for QuitRiskPolicy (INT-217).** Prompt markers are the
   one PTY-borne semantic worth keeping over the wire; zmx already forwards and
   massages OSC 133;A. The work is **injecting shell integration into the daemon's
   shell** (`GHOSTTY_RESOURCES_DIR` + integration), since setting
   `surfaceConfig.command` bypasses libghostty's auto-injection and the daemon
   otherwise forks a bare login shell that emits no markers. Move QuitRiskPolicy
   onto `amx wait` (daemon idle) rather than display state; quitting stops being
   destructive once nothing dies with the app.

6. **Terminal identity reads `awesoMux`.** Process-tree terminal detection
   (fastfetch et al.) reports the daemon's process name, so the vendored daemon
   ships as `amx`; keep `TERM=xterm-ghostty` (deliberate Claude-Code contrast
   reason in `TerminalAppearancePreferences.swift`) and consider
   `TERM_PROGRAM=awesoMux`.

The deliverable that follows this ADR is the full build, scoped by the follow-ups
in **Consequences**.

## Spike findings (evidence)

Build/toolchain (Experiment A):
- zmx and our `vendor/ghostty` both pin **`minimum_zig_version = 0.15.2`**;
  installed `zig 0.15.2`. `zig build` → standalone `amx`/`zmx` binary in one shot.
- zmx pins its **own** ghostty via the Zig package manager and links **none** of
  our `vendor/ghostty`. The bridge is two independent VT parsers over a PTY byte
  stream, so the feared "libghostty-vt version coupling" is **not an ABI coupling
  at all** — the two ghostty SHAs never have to agree.
- zmx ships primitives that map onto the roadmap: `wait` (idle → QuitRiskPolicy),
  `history --vt` (scrollback), `list`/`kill` (orphan GC).

Bridge round-trip (Experiment B), isolated state, verified visually:
- Surface spawned `amx attach <uuid>` → daemon `clients=1`, rendered.
- Killed the app → daemon survived (`clients=0`, same pid), `sleep 999` alive,
  scrollback marker retained.
- Relaunched → restored pane (same UUID) reattached to the same daemon
  (`clients=1`), same `sleep 999` pid, marker rendered in the surface.

Semantic-passthrough harness (the real gate):
- Env propagation works (`TERM_PROGRAM`/`TERM` reached the inner shell).
- No shell integration in the inner shell (`GHOSTTY_*` absent) → no auto-emitted
  OSC 7/133.
- Title (OSC 2) forwards live; cwd (OSC 7) is not forwarded (zmx tracks it via
  IPC); reattach sends a reconstructed snapshot, not a byte replay → the
  "reattach OSC cliff," confirmed in zmx source.

Constraints found:
- **zmx session names cap at 46 bytes** (unix socket path length); a bare UUID
  (36) fits, prefixes overflow — the id scheme must account for this.
- Setting `command` auto-sets `wait_after_command=true`; on client/daemon exit the
  surface shows "Press any key to close" — production must **respawn on detach**
  and distinguish detach from daemon death.
- `$HOME` does not isolate a launchd-spawned GUI app (`NSHomeDirectory` resolves
  from the user record); the spike used a code-level state-dir override.

## Consequences

- **The differentiator is safer than feared.** Agent state already lives off the
  PTY, so the nested VT does not threaten the agent-native sidebar — only env
  propagation does, and that works.
- **`amx` is load-bearing.** It is the persistent-terminal backend contract
  (attach lifecycle, idle/`wait`, cwd, history, name limits, error parsing) plus
  the out-of-band semantic channel. Underspecifying it is the main way zmx
  specifics leak and the reversal path dies.
- **Reboot is still not covered** (PTY lives in RAM); a separate, harder problem,
  explicitly out of scope.

Follow-ups to track in Linear before/with the full build (several raised by the
cross-model review):

- **Lifecycle matrix spike**, not single-kill: crash mid-`session-state` write,
  stale pane records on relaunch, many panes, rapid create/close, force-killed
  daemon, duplicate window, resize storms, dotfile startup.
- **OSC 133 + shell-integration injection** into the daemon shell, verified live
  and after reattach with real zsh/bash/fish. The **QuitRiskPolicy rewire (INT-217)
  landed independently** of the shell-integration work: quit-risk now uses libghostty
  `foreground_pid` + a libproc child check (catching background jobs) with OSC 133
  kept as corroboration; the `amx wait` idea was rejected (it only tracks `run` tasks,
  not interactive foreground processes). Shell-integration injection + an `amx`-sourced
  prompt/idle oracle remain a later increment (PR2).
- **cwd via `amx`** wired into the path bar (replacing OSC 7 reliance).
- **Daemon GC as product policy** — daemons outlive the app and otherwise
  accumulate without bound.
  - **Increment 1 — launch-time orphan GC: LANDED (INT-570).** Reaps idle,
    unattached, UUID-named daemons with no owning pane / reopen entry at launch;
    spares busy (`clients>0` or a live foreground process) ones; aborts if the
    `ps` snapshot is unavailable; gated off when restore is disabled or a
    recovery warning is unresolved. **Ownership is enforced by a dedicated 0700
    per-user, profile-scoped socket dir** (`ZMX_DIR =
    NSTemporaryDirectory()/amx` for production, `NSTemporaryDirectory()/amx-dev`
    for the primary dev bundle, and a stable seven-character namespace for each
    linked worktree) so GC — and `amx list`/`kill` — can only ever
    see that profile's awesoMux-owned daemons; a user's hand-run `zmx`/`amx`
    sessions in zmx's default dir are invisible by construction, and a dev build
    cannot reap the installed app's daemons. UUID-shape is a secondary fence.
    Manual stopgap [`script/amx-reap.sh`](../../script/amx-reap.sh) points at
    the production dir by default, accepts `--dev` for the primary dev profile,
    and accepts `--profile development:<worktree-id>` for linked worktrees.
  - **Still to come:** reap-on-permanent-close (the main bound; ties to the
    INT-282 soft-close vs permanent-close distinction), an opt-in idle/age cap
    with a user **pin** (the "forever" backstop), and a session-manager surface
    for visibility. States: owned / detached-restorable / abandoned / expired /
    user-pinned; surfaced in UI before any destructive kill. **Accessibility
    (when the session-manager UI lands):** convey daemon state (idle/busy/owned)
    with text + icon, not color alone, and announce state changes — the
    busy/idle/owned classification GC already computes is the data model for it.
  - **Known v1 ceiling:** the process-tree idle check is evidence, not prompt
    state — a shell busy in a builtin/`read`-loop with no child reads as idle;
    acceptable because reaping also requires `clients==0` + the bridge ships off.
    Upgrade path is an `amx`-sourced prompt/idle signal (shared with INT-217).
- **Durable `TerminalSessionID`** mapping + uniqueness/migration rules; fixed
  short encoded daemon names (≤46 bytes); zmx ids in a backend-private blob.
- **Daemon-death supervisor**: turn a dead session into a recoverable error pane,
  not "press any key"; respawn-on-detach.
- **Multi-attach semantics** (single-client lock vs read-only mirror vs intentional
  multi-client) decided before shipping; **resize authority** through attach
  tested against vim/less/htop/curses across detach/reattach.
- **Per-session socket security**: `0700` user-owned runtime dir, reject
  symlink/path tricks, handle stale sockets.
- **Scrollback fidelity** compared before/after reattach for color/hyperlinks/
  prompt regions/alt-screen/wrapped lines, not just visible text. Excluded:
  kitty/sixel graphics placements are not part of the persisted cell grid and
  are dropped on reattach — an upstream libghostty-vt snapshot limitation
  shared with tmux and most multiplexers.
- **Error-reason granularity** before default-on: detach, daemon-loss, and
  missing `amx` should not collapse to one `.error`; carry a reason enum so UX,
  accessibility, and recovery can distinguish reconnecting, lost session, and
  missing backend.
- **Accessibility of bridge states** before default-on: announce bridge
  connection-lost / reattach-succeeded with pane title, include pane execution
  state in title-bar accessibility labels instead of color-only state, move
  focus off a disposed focused surface when a pane enters `.error`, and consider
  a retry-reconnect accessibility action.
- **Preflight probe caching** before default-on: cold restore currently risks one
  `amx list --short` subprocess per established pane; cache verified-live
  `TerminalSessionID`s per runtime so many-pane restores and repeated restores do
  not re-probe every pane.
- **Config-flip-off policy** before default-on: decide whether flipping
  `terminal.command_bridge_enabled` off should force live bridged surfaces back
  to local shells or remain documented as applying on the next surface
  lifecycle.
- **Recently-closed reopen dedup** before default-on: verify the reopened
  workspace path applies the same `TerminalSessionID` uniqueness guarantees as
  snapshot restore, so reopen cannot collide an active pane and multi-attach a
  single daemon.

## Alternatives considered

- **Native Swift daemon now** — rejected for the spike: the VT-snapshot/replay
  machinery is the hard 80% and already exists, works, and is MIT. The `amx` seam
  preserves this as the reversal path if the Zig dependency or one-daemon-per-
  session model becomes a maintenance pain.
- **Direct fd-attach (surface adopts the daemon's PTY)** — impossible via the
  public libghostty API (no fd field); would require forking libghostty.
- **Scrape semantics from forwarded OSC** — rejected: zmx's reattach snapshot
  carries no OSC state, and it tracks cwd out-of-band anyway; out-of-band via
  `amx` is both more robust and the pattern already in use for agents.

## Update 2026-06-25 — out-of-band protocol landed (INT-572 + cwd-via-amx)

The "out-of-band semantics" follow-ups are now implemented behind
`terminal.command_bridge_enabled` (still default OFF).

- **`amx` now exposes three signals.** (1) created-vs-attached + (2) session-end
  reason ride a per-attach status side-channel file (`AMX_STATUS_FILE`, JSONL,
  kqueue-watched, forgery-token-guarded); (3) live cwd via a new `CwdQuery`/
  `CwdResponse` IPC + `amx cwd <id>` subcommand (`proc_pidinfo` on the root shell).
  The status env is `unsetenv`'d at the shared daemon-creation chokepoint so it
  can't leak into the inner shell.
- **End-reason correction.** The attach client cannot infer the reason from socket
  observations (validated: `kill -9` daemon → client only sees raw EOF → `unknown`;
  app-quit/client-kill → no line at all). So the daemon sends a `SessionEnd` IPC on
  orderly shutdown, and the policy **fails safe**: absent-or-`unknown` → silent
  non-destructive respawn (the INT-571-validated behavior). This unblocks INT-572
  (runtime respawn + correct chrome on respawn + a11y announce).
- **Respawn bounding ceiling.** A `CommandBridgeRespawnLedger` bounds crash loops,
  but only for loops whose period is shorter than the uptime grace window; a daemon
  that survives the grace window each cycle refills and respawns indefinitely (by
  design — standard restart-rate-limiting; the respawn is non-destructive). Upgrade
  path if abuse appears: a sliding-window attempt count.
- **zmx fork.** The Zig patches live on `main` of the **public**
  awesoMux-maintained fork `Interactive-Buffoonery/zmx` (`vendor/zmx`, HTTPS
  submodule; no CI token needed — INT-624). General fixes may be upstreamed to
  `neurosnap/zmx` opportunistically; the AMX protocol stays a fork feature.
  Recurring cost: each zmx pin-bump rebases the fork onto upstream `main`.
- **Pre-default-on polish (deferred, follow-up):** reader 0600 mode-bit check;
  kqueue `.write`+`.extend` double-drain; `daemon_pid:0` probe-failure aliasing
  fresh-vs-reconnect; bridged non-zero shell-exit error badge; path-bar cwd poll
  interval/backoff. None block the disabled-default merge.

## Update 2026-07-15 — authenticated daemon-PTY foreground evidence (INT-835)

The same per-attach `AMX_STATUS_FILE` channel now carries typed
`foreground-process` publications sampled from the persistent daemon's PTY.
They contain only the process-group id and executable name, plus the daemon
pid/creation/incarnation identity and monotonic transition/sample sequences —
never arguments, environment, terminal contents, paths, or credentials.

awesoMux accepts a publication only after the matching authenticated `attached`
event. The attach event's zero incarnation is an explicit unknown-nonce sentinel;
the first matching foreground publication supplies the nonzero daemon nonce, and
later publications must match it exactly. A new attach generation, session end,
daemon-identity mismatch, replay or sequence regression, malformed payload, and
explicit `stale` state all clear usable evidence. The read seam is tri-state
(matching, non-matching, unknown), runtime-only, and separate from
`PaneExecutionPlan` / `ExecutionLocation`: it can deny a future action but cannot
grant host or path authority.

## Update 2026-06-25 — config flip-off policy resolved (§223–226)

**Decision: next-lifecycle, non-destructive.** Flipping
`terminal.command_bridge_enabled` OFF does **not** tear down live bridged
surfaces. New surface decisions honor the flip immediately; surfaces already
attached to a daemon keep running until they are recycled, closed, or the app
relaunches; on relaunch every surface comes up as a local shell and the now-
orphaned daemons are reaped by launch-time GC (INT-570).

| Event (flag just flipped OFF) | Behavior |
| --- | --- |
| Existing bridged pane, mid-session | Keeps running — daemon survives |
| Newly opened pane, same session | Local shell immediately |
| All panes, after relaunch | Local shell |
| Old daemons, after relaunch | Reaped by launch GC |

This **ratifies the current emergent behavior** rather than adding code:
`isCommandBridgeEnabled` is a live-read computed property
(`GhosttyRuntime.commandBridgeEnabledProvider()`), evaluated fresh at the
create-time `.bridge`-vs-`.localShell` decision and at exit supervision. No code
path tears a running surface down on a flag change, so the only deliverable is
this documentation (plus, when the settings UI lands, a hint that the toggle
"applies to new sessions; existing sessions keep running until closed").

**Why not eager teardown:** forcing live bridged surfaces back to local shells
on a config edit would abandon running processes and scrollback — the exact
blank-pane / data-loss failure the INT-571/572 robustness work eliminated.
Opt-out should leave the user's daemons restorable/reapable via GC and the
future session-manager surface, never force-kill them. The surviving daemon is
the feature; a rare, deliberate flag flip is not a reason to destroy it.

This closes the last non-smoke item blocking default-on. Remaining gate: the
live validation pass in
[`docs/testing/command-bridge-default-on-smoke.md`](../testing/command-bridge-default-on-smoke.md).

## Update 2026-07-07 — corrections from the amx automation doc (INT-752)

[`docs/amx-automation.md`](../amx-automation.md) now documents the blessed
`amx` automation surface and cross-links this ADR; verifying its claims
against `vendor/zmx` source retired two statements above. Per ADR etiquette
they stand corrected here rather than edited in place:

- **Decision §5 ("Move QuitRiskPolicy onto `amx wait` (daemon idle)") and the
  spike finding "`wait` (idle → QuitRiskPolicy)": superseded.** `amx wait`
  only tracks tasks started with `amx run -d`; it cannot detect pane-idle or
  an interactive foreground process finishing. The QuitRiskPolicy rewire
  (INT-217) landed on libghostty `foreground_pid` + a libproc child check
  instead — as the Consequences follow-up above already records. Do not point
  quit-risk or daemon-idle direction at `amx wait`.
- **"zmx session names cap at 46 bytes": misattributed.** zmx's actual limit
  is the total socket path — `$ZMX_DIR` + `/` + name must fit `sockaddr_un`
  (~103 usable bytes; `vendor/zmx/src/socket.zig:77-94,115-120`), so the name
  budget shrinks as `ZMX_DIR` grows. The 46-byte figure is awesoMux's own pin
  (`TerminalSessionID.maxAmxSessionNameUTF8Bytes`), sized for the dev
  socket-dir worst case. Bare UUIDs (36 bytes) fit under both.
