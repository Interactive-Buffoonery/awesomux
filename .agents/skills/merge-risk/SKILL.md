---
name: merge-risk
description: Assess how risky a change is to merge and where human attention would help most. Use after preflight and before opening a pull request, or when asked for merge risk on a branch or PR. Read-only and advisory.
---

# Merge risk

Assess the exposure left in a change, for reviewers. This is not merge approval
or a gate. Do not edit, build, run tests, start reviewers, post comments, or
merge. `script/terminal-lifecycle-e2e/run.py --check-freshness REPORT` is allowed.

## Evidence

Reuse results from this revision, then read the diff and its callers. Missing,
older, or inconclusive evidence is unknown, never passing.

- Required PR checks are guards. They never build or test Swift.
- `./script/preflight.sh` proves guards, tests, and that a dev-signed app launches
  and quits. `--checks-only` omits that launch and is not a pass. Neither runs a
  journey, SSH, or release signing.
- `/ci` is on demand, never launches the app, and skips announcement tests.

## Where risk lives

Harnesses are under `script/`.

| The diff touches | Failure | Proof preflight lacks | What a revert leaves |
| --- | --- | --- | --- |
| `AmxBackend`, daemon cleanup, close and quit, `vendor/zmx` | Running work ends or is replaced | `terminal-lifecycle-e2e/run.py`, `amx-reap-e2e.sh` | Ended processes and scrollback are gone |
| `SessionSnapshot`, `SessionPersistence`, settings, access and install stores | Older builds refuse newer files | Quit and relaunch on a real snapshot | Newer files stay on disk for older builds to read |
| `vendor/ghostty`, `native/`, `prepare_ghostty_source.py` | Panes stall, garble, or crash | `terminal-lifecycle-e2e/run.py`, the features the pin changes | Nothing saved; intermittent stalls are hard to attribute |
| `AwesoMuxBridge*`, `RemoteHelperInstaller`, SSH commands | Wrong command or file on a host | `ssh-terminal-e2e/run.py`, `verify-remote-markdown-transport.py`, `test-remote-browser-e2e.sh` | Helpers and `~/.terminfo` stay on hosts |
| `AwesoMuxLocalAPI*`, `Companion*`, permissions | Wider access to terminals | `run_companion_pairing_e2e.sh`, `local-api-e2e/`, `local-permission-e2e/` | Grants persist; phones ship separately, so keep wire changes additive |
| `AwesoMuxAgentHook*`, `Resources/AgentIntegrations` | Provider config changed; wrong pane status | `agent-plugin-config-home-e2e/run.py`, `codex-shared-server-e2e/run.py` | Installed plugins stay; keep legacy identities |
| `release.yml`, `build_release.sh`, `UpdateController`, entitlements, keys, workflows | Installs stop updating | Dispatch to a draft; ADR-0019 checks | Key loss needs a manual reinstall |
| Menus, shortcuts, focus, confirmations, accessibility | Lost command, input in the wrong pane, or unsafe close | `menu-e2e/run.py`, `terminal-lifecycle-e2e/run.py`, a native check; screenshots do not prove input routing or speech | Nothing |

[`docs/ci.md`](../../../docs/ci.md) lists the other harnesses. A harness that
cannot run here counts as not proved.

## Judge

Check alignment with the linked issue, then the row, its reach, and its proof.

- **Timing:** A revert helps only until the next tag, often within days. After
  that, withdraw the release and ship a new version.
- **Detection:** There is no telemetry (ADR-0008). Failures surface through user
  reports, local logs, and recovery warnings. Say which, or say none.

Use low, medium, high, or unknown. High: a failure ends running work, loses restore
state, widens access, or strands installs, and that row's proof did not run at
this revision. Never low without preflight and the row's proof, or with an open
security finding. Docs-only changes need `git diff --check`, and are low unless
they change an ADR or journey contract.

## Report

Return one line for `Merge risk:` under Notes: the level, the main reason, and how
to recover. Write it, and any update to it, in simple English or ASD-STE100
(Simplified Technical English).

> Merge risk: high. Changes daemon cleanup, so a bug could end sessions on
> relaunch. Recovery: a revert stops further loss but cannot restore ended
> sessions.

When asked for the full assessment, add the revision, one line per row touched,
and the next action that would most reduce risk.
