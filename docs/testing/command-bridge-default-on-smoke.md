# Command-Bridge Default-On Smoke Playbook

**Purpose:** the live-validation gate before flipping `terminal.command_bridge_enabled`
from default-OFF to default-ON. Static review + `swift test` + preflight cannot
exercise the multi-process, async-respawn, status-file-race behaviors the bridge
introduces — those only show up with a real daemon, real shells, and a human
driving the app. This is that pass, structured and recorded.

**Gate it satisfies:** the "before default-on" follow-ups in
[ADR-0011](../adr/0011-persistent-session-daemon-command-bridge.md) — the
lifecycle-matrix spike (lines 164–166), scrollback fidelity (208–209),
shell-integration/OSC 133 (167–173), multi-attach (203–205), config-flip-off
(223–226), and recently-closed reopen dedup (227–230). The runtime-respawn,
error-reason, a11y, and cwd-via-amx items (210–218, 174) landed in INT-571/572
and are re-confirmed here, not re-implemented.

**How to use:** run top to bottom on a fresh build. Each scenario has a
pass/fail box — fill it in. The exit criteria at the bottom defines "safe to
flip." File any failure as a GitHub issue and link it in the
scenario's notes before calling the pass complete. A partial pass with open
failures does **not** clear the gate.

---

## 0. Preconditions (do not skip)

The single most common way this playbook lies to you is smoke-testing a **stale
bundled `amx`** — a binary built before the out-of-band patches. If the bundle
is stale, the status side-channel and `amx cwd` silently do nothing and every
INT-572 scenario below "passes" by being a no-op.

- [ ] **P1. Fresh build.** `./script/build_and_run.sh` from a clean tree on the
  commit under test. Record the SHA in the results header.
- [ ] **P2. Verify the bundled `amx` is the patched build, not stale.** The
  `build_and_run` skip-if-staged footgun has bitten before. Confirm:
  - `amx cwd <some-live-id>` returns a path (not an error / empty), **and**
  - `strings "$(path-to-bundled-amx)" | grep -q AMX_STATUS_FILE` succeeds.
  - If either fails, the bundle is stale — rebuild `amx` before continuing.
- [ ] **P3. Flag ON.** Set `terminal.command_bridge_enabled = true` in
  `~/.config/awesomux/config.toml` (this is the *manual* enable that default-on
  will make implicit — we are validating that path). For the primary dev bundle,
  use `~/.config/awesomux-dev/config.toml`; linked worktrees use
  `~/.config/awesomux-dev-<worktree-id>/config.toml`.
- [ ] **P4. Know where the daemons live.** Sockets are under
  `$TMPDIR/amx` for production, `$TMPDIR/amx-dev` for the primary dev bundle,
  and the profile's short namespace for linked worktrees (0700, awesoMux-owned).
  `script/amx-reap.sh` uses `AWESOMUX_PROFILE` inside a pane; outside one, use
  `--dev` or `--profile development:<worktree-id>`. Keep a second terminal open
  here to inspect/kill daemons during scenarios.
- [ ] **P5. Clean slate.** No leftover daemons: `amx list` is empty (or run
  `script/amx-reap.sh`, or `script/amx-reap.sh --dev` for dev). Start each
  major section from a known-clean daemon set.

**Results header (fill in per run):**

```
Date:            2026-__-__
Build SHA:       ____________
Bundled amx:     verified patched (P2) ☐
Shells tested:   zsh ☐  bash ☐  fish ☐
macOS version:   ____________
Driver:          eD
Overall verdict: PASS ☐   PASS-WITH-OPEN-ISSUES ☐   FAIL ☐
```

---

## A. Lifecycle matrix (ADR-0011 §164–166)

The core spike. Each is a state the bridge must survive without blank panes,
latched errors, or corrupted persistence.

- [ ] **A1. Clean quit + relaunch.** Open 3–4 workspaces with running shells (cd
  somewhere non-`$HOME`, run a long-lived `top`/`tail -f` in one). Quit awesoMux
  (⌘Q). Relaunch.
  **Expect:** every pane reattaches to its surviving daemon, scrollback intact,
  the `top`/`tail` still running, cwd preserved. No blank/error panes.
  Notes: ____________

- [ ] **A2. Many panes.** Open 12+ panes across workspaces (the INT-571 live-repro
  count). Quit + relaunch.
  **Expect:** all reattach or silently respawn; relaunch is not visibly
  serialized/janky per-pane; no pane latches `.error`.
  Notes: ____________

- [ ] **A3. Force-killed daemon, app closed.** With the app quit, `kill -9` a
  couple of the surviving daemons (`amx list` → pick PIDs). Relaunch.
  **Expect:** panes whose daemon is gone respawn into a fresh working shell
  (non-destructive, INT-571 restore path) — not blank, not "press any key".
  cwd falls back to persisted `workingDirectory`.
  Notes: ____________

- [ ] **A4. Rapid create/close.** Quickly open and close ~10 panes in a burst
  (⌘T / ⌘W rhythm). Then `amx list`.
  **Expect:** no orphaned daemons accumulate beyond what owns a live pane;
  launch-time GC (INT-570) reaps the rest on next relaunch. No crash, no
  half-created surfaces.
  Notes: ____________

- [ ] **A5. Resize storms.** With a curses app running (`htop`/`vim`/`less`) in a
  bridged pane, drag the window + sidebar divider rapidly, toggle fullscreen,
  resize repeatedly.
  **Expect:** the curses app reflows correctly through attach; no prompt
  duplication beyond the known ghostty/OSC133 resize behavior (that's a shell-
  integration issue, not a bridge regression); no detach.
  Notes: ____________

- [ ] **A6. Dotfile startup.** Use a shell with a heavy rc (starship/p10k,
  `fastfetch`, completions). Open a bridged pane, quit, relaunch.
  **Expect:** the rc runs once on daemon creation; reattach does **not** re-run
  it (you're attaching to a live PTY, not spawning a new shell). No doubled
  banner. (Cross-check INT-171 image-artifact behavior separately.)
  Notes: ____________

- [ ] **A7. Crash mid-persist.** Hardest case. Open several panes, then force-quit
  awesoMux during shutdown / with `kill -9` on the app while `session-state` is
  being written (or pull the rug: kill the app immediately after a layout
  change). Relaunch.
  **Expect:** relaunch either restores the last good state or surfaces a recovery
  warning — it does **not** restore stale/garbage pane records that point at
  daemons that don't exist, and does not crash-loop on launch.
  Notes: ____________

---

## B. Runtime respawn & end-reason (re-confirm INT-572)

Validates the out-of-band session-end signal and the respawn decision **while
the app stays open** — the path INT-572 added on top of INT-571's restore path.
Respawn is driven by the status-channel session-end event, **not** libghostty's
process-exit callback (which defers behind `wait_after_command`'s "press any
key").

- [ ] **B1. Clean shell exit → no respawn.** In a bridged pane, type `exit`.
  **Expect:** the pane ends cleanly (closes / shows ended state per design) — it
  does **not** silently respawn a new shell. End-reason = `shellExit`.
  Notes: ____________

- [ ] **B2. Daemon killed mid-session → silent respawn.** With the app open and
  focused on a bridged pane, `kill -9` that pane's daemon from the side terminal.
  **Expect:** the pane respawns into a fresh working shell automatically
  (non-destructive). End-reason observed = `unknown` (raw EOF) → fail-safe
  respawn. No blank pane, no latched `.error`, no "press any key".
  **Run this TWICE — single-pane workspace AND a 2-pane split** — the heal must
  preserve the split (respawn the dead pane in place, sibling untouched), not
  collapse it. Note `amx list` before/after: the respawned daemon must re-attach
  (`clients=1`), not end orphaned (`clients=0`).
  Notes: ____________
  > ⚠️ Known failure (2026-06-25): the **split variant** collapses the split
  > instead of healing in place — tracked in **INT-574** (default-on blocker).
  > Single-pane variant passes.

- [ ] **B3. Respawn clears stale chrome.** Make the killed pane (B2) an *agent*
  pane first (run `claude`/`codex`, let it reach a "waiting"/attention state),
  then `kill -9` the daemon.
  **Expect:** after respawn the pane is a plain shell with **no** stale
  `agentKind` label and **no** stale attention/unread badge. The "Claude,
  waiting" chrome does not survive onto `/bin/zsh`.
  Notes: ____________

- [ ] **B4. Respawn announces to VoiceOver.** Repeat B2 with VoiceOver on.
  **Expect:** an announcement fires naming the pane / the recovery (per Task 12
  a11y). State conveyed by text, not color alone.
  Notes: ____________

- [ ] **B5. Live cwd after respawn.** In a bridged pane, `cd` deep into a tree.
  Kill the daemon (B2) and let it respawn; also separately just `cd` around in a
  healthy bridged pane.
  **Expect:** the path bar reflects the daemon's **live** cwd via `amx cwd`, not
  a stale persisted path. (Title-less prompts rely on the poll; prompts that
  embed cwd/branch in the title update near-live for free.)
  Notes: ____________

- [ ] **B6. Crash-loop is bounded.** Script a daemon that dies immediately on
  spawn (e.g. an `amx` session whose command is `false`/exits instantly), within
  the uptime grace window.
  **Expect:** `CommandBridgeRespawnLedger` stops the loop after the bounded
  attempts rather than respawning forever; the pane lands in a recoverable error
  state, not an infinite flicker. (A daemon that survives the grace window each
  cycle is *expected* to keep respawning — that's by design.)
  Notes: ____________

---

## C. Scrollback & render fidelity across reattach (ADR-0011 §208–209)

Visible text is the easy part; the regression risk is in the formatting layers.

- [ ] **C1. Color + styles.** Run `ls --color` / a colorized git log / a TUI with
  themes. Quit + relaunch.
  **Expect:** colors, bold/dim, and 256/truecolor survive reattach.
  Notes: ____________

- [ ] **C2. Hyperlinks (OSC 8).** Emit an OSC 8 hyperlink (e.g. a tool that prints
  clickable links). Reattach.
  **Expect:** the link region is preserved and still clickable.
  Notes: ____________

- [ ] **C3. Wrapped lines + prompt regions.** Fill the pane with long wrapped
  lines and several prompts. Reattach.
  **Expect:** wrap points and OSC 133 prompt regions are intact; no reflow
  corruption.
  Notes: ____________

- [ ] **C4. Alt-screen.** Be inside `less`/`vim` (alt-screen) at quit time.
  Reattach.
  **Expect:** you return to the alt-screen app in its prior state; exiting it
  restores the primary screen + scrollback cleanly.
  Notes: ____________

---

## D. Shell-integration / OSC 133 through the daemon (ADR-0011 §167–173)

The nested-VT path must not break prompt-marker-driven features. (Full
shell-integration *injection* is a later increment/PR2; here we confirm nothing
regressed for shells that already emit markers.)

- [ ] **D1. Idle↔running chrome.** With a marker-emitting shell, run a long
  command then let it finish.
  **Expect:** sidebar/pane chrome tracks running→idle correctly through the
  bridge, same as local-shell mode.
  Notes: ____________

- [ ] **D2. Quit-risk (INT-217).** Start a foreground process (e.g. `sleep 300`,
  or a background job) in a bridged pane, attempt ⌘Q.
  **Expect:** quit-risk fires off `foreground_pid` + libproc child check — the
  confirm prompt appears for the busy pane. (Quit-risk uses process liveness, not
  `amx wait`.)
  Notes: ____________

- [ ] **D3. Per-shell sanity.** Repeat D1 on each of zsh / bash / fish you're
  certifying. Tick the shells in the results header.
  Notes: ____________

---

## E. Multi-attach & duplicate window (ADR-0011 §203–205)

- [ ] **E1. Duplicate-window / double-attach guard.** Try to get two surfaces
  attached to the same `TerminalSessionID` (open a duplicate window, or restore +
  reopen the same workspace).
  **Expect:** the single-client model holds — no two live surfaces fighting over
  one daemon, no input doubling, no resize tug-of-war. Whatever the decided
  semantics (single-client lock / read-only mirror), behavior is consistent and
  not corrupting.
  Notes: ____________

- [ ] **E2. Resize authority through attach.** With vim/htop/less running, detach
  (quit) and reattach (relaunch) at a *different* window size.
  **Expect:** the curses app picks up the new size correctly on reattach.
  Notes: ____________

---

## F. Recently-closed reopen dedup (ADR-0011 §227–230)

- [ ] **F1. Reopen does not collide an active pane.** Open workspace W (bridged).
  Soft-close it (⌘W → recently-closed). Reopen it. Separately, ensure a *fresh*
  snapshot-restore of the same session can't run concurrently.
  **Expect:** reopen applies the same `TerminalSessionID` uniqueness guarantee as
  snapshot restore — it reattaches the one daemon, it does not spin a second
  attach against a live daemon (no multi-attach via the reopen path).
  Notes: ____________

---

## G. Fallback safety — flag ON, `amx` missing (degraded default)

Default-on means users with a broken/absent bundle must still get a working
terminal. This is the graceful-degradation contract.

- [ ] **G1. Missing `amx` → clean local shell.** Temporarily rename/remove the
  bundled `amx` (or point the resolver at a non-existent path) with the flag ON.
  Open a pane.
  **Expect:** the pane comes up as a normal login shell (`.localShell`
  fallback), no error latch, no blank pane, no orphaned `.status.jsonl` left
  behind. A diagnostic is logged but the user is not blocked.
  Notes: ____________

- [ ] **G2. No status-watcher leak in fallback.** After G1, confirm no status
  watcher is armed and the path bar isn't polling a dead id.
  Notes: ____________

---

## Open decision blocking the flip (not a smoke item)

- [x] **Config-flip-off semantics (ADR-0011 §223–226).** **Resolved
  2026-06-25 — next-lifecycle, non-destructive.** Flipping
  `terminal.command_bridge_enabled` OFF leaves live bridged surfaces running
  (daemon survives); new surfaces go local immediately; on relaunch all panes
  come up local and orphaned daemons are GC'd. Ratifies the current live-read
  behavior — no teardown code. See
  [ADR-0011 § "Update 2026-06-25 — config flip-off policy resolved"](../adr/0011-persistent-session-daemon-command-bridge.md).

---

## Exit criteria — "safe to flip the default"

The gate clears when **all** of:

1. Every scenario in A–G is checked PASS, **or** has a linked GitHub issue with
   an explicit "does not block default-on" rationale signed off by eD.
2. Sections A, B, and G have **zero** open failures (these are the
   data-loss / blank-pane / can't-recover risks — no soft-passes here).
3. The config-flip-off decision is made and documented.
4. The results header is filled in (build SHA, shells, verdict) and this file is
   committed as the validation record for that SHA.

When all four hold, flipping `DefaultCommandBridgeEnabled.defaultValue` to `true`
(`Sources/AwesoMuxConfig/TerminalConfig.swift`) is a one-line change backed by a
recorded validation pass.

> **Note on go-public:** making the private `Interactive-Buffoonery/zmx` fork
> public (or upstreaming the patches) and dropping `ZMX_SUBMODULE_TOKEN` from CI
> is a separate **go-public** gate (ADR-0011 §268–273), not a default-on gate.
> The default can flip while the repo is still private.
