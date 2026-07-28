# ADR-0023: Remote workspace architecture — awesoMux composes with SSH

## Status

Accepted

Updated 2026-07-16 to match the narrowed remote-workspace scope in INT-691 and
INT-699. Earlier plans for host profiles, target-side installers, remote zmx
management, provider adapters, and broad remote-workflow certification are not
prerequisites for the shipped SSH workspace or the remaining paste outcome.

## Context

awesoMux runs a persistent local session daemon behind the `amx` seam
([ADR-0011](0011-persistent-session-daemon-command-bridge.md)). Each terminal
surface starts `amx attach <id>` rather than adopting an existing PTY or socket;
libghostty does not expose a field for attaching one.

A declared remote pane extends that existing command bridge with an SSH child:

```text
libghostty surface -> local amx session -> ssh <declared target> -> remote shell
```

The local daemon owns persistence. The remote host needs only SSH and a shell.
This is an SSH workspace, not a second remote session-management platform.

Related decisions:

- [ADR-0011](0011-persistent-session-daemon-command-bridge.md) defines the
  local command bridge and persistence owner.
- [ADR-0021](0021-remote-markdown-uses-submitted-ssh-target.md) requires remote
  Markdown to use declared execution identity rather than terminal titles.
- [ADR-0022](0022-ssh-credential-custody-and-transport.md) keeps credentials in
  OpenSSH and limits awesoMux to transport configuration it owns.

## Decision

### 1. The pane execution plan is authority

`PaneExecutionPlan.ssh` contains the declared `RemoteTarget` used to build the
SSH command and identify remote resources. A workspace group's remote target is
only a creation default and legacy migration source. Runtime titles, prompts,
observed SSH commands, `remoteHost`, `remoteSSHTarget`, and later selection
changes do not grant remote-action authority.

The target remains the user's OpenSSH destination, including aliases from
`~/.ssh/config`. awesoMux does not resolve it or maintain a parallel host-profile
store.

### 2. The local daemon owns persistence

Remote panes use local `amx` persistence around an SSH child. awesoMux does not
discover, attach, manage, or kill remote zmx sessions, and it does not nest a
remote persistence daemon inside the local one. A future remote-session product
would require a separate decision and demonstrated user need.

### 3. OpenSSH owns transport and credentials

awesoMux never stores, prompts for, caches, or transmits passwords,
passphrases, or keys. It supplies only the connection multiplexing, bounded
connection setup, and keepalive options defined by ADR-0022. Host-specific
OpenSSH configuration remains
authoritative, including proxying and agent-forwarding choices.

A remote pane that cannot build its declared command fails visibly. It never
falls back to a local shell, another host, or title-derived identity.

### 4. Remote agent signaling is optional infrastructure

The local JSONL agent side channel cannot cross SSH: its path, ownership checks,
and `kqueue` watcher all belong to the local filesystem. The shipped
authenticated bridge may provide remote agent signals when a compatible helper
is available. A missing or incompatible helper may be installed only through an
explicit, user-approved remediation; installation is never an ordinary SSH
workspace prerequisite. Provider-specific adapters and remote idle detection
remain outside this architecture's required path. Their absence must not prevent
an ordinary SSH terminal from working.

### 5. Remaining file handoff is deliberately small

INT-699 adds one Command-V flow for one local clipboard image or copied Markdown
file in a declared remote pane:

1. capture the originating pane and its declared execution plan;
2. validate one bounded local source;
3. confirm the declared destination host and filename;
4. transfer to a unique remote path;
5. revalidate the original pane identity; and
6. insert one shell-safe remote path without submitting it.

The declared pane identity chooses the destination. The operation never exposes
the local absolute path to the remote host, silently changes hosts, or inserts
anything after a failed validation or transfer.

Batch transfer, drag-and-drop, progress aggregation, retry systems, remote file
browsing, synchronization, provider-native attachment, setup tooling, and a
transport abstraction for hypothetical implementations are non-goals.

## Consequences

- Remote SSH workspaces keep the existing local `amx` lifecycle and need no
  preinstalled helper. The optional helper installer is user-approved and only
  remediates rich bridge and file-handoff capabilities.
- `PaneExecutionPlan` is the single durable authority for remote actions and
  resource identity; runtime SSH observations remain presentation and safety
  heuristics only.
- OpenSSH configuration handles aliases, proxies, authentication, and forwarding.
- Rich remote agent state may degrade independently while the terminal remains
  usable.
- Broader remote-development features return only as separately justified
  outcomes, not as hidden prerequisites for INT-699.

## Limitations

- awesoMux remains macOS-only; remote targets are reached through SSH.
- The local daemon can preserve the SSH process across app quit, but it cannot
  promise survival across a reboot or independently recover a remote shell after
  the SSH process ends.
- A remote process cannot use the Mac-local agent file-drop channel.
- The remaining handoff supports one confirmed clipboard item, not a general
  remote filesystem workflow.

## Amendment (#87, 2026-07-22): Linux destinations supported via a manual static helper

Linux destinations are supported via a manually installed static helper; see
[`docs/remote-linux-helper.md`](../remote-linux-helper.md).

## Amendment (#214, 2026-07-24): a pane may opt into remote-owned zmx persistence

§2's "the local daemon owns persistence" and "awesoMux does not discover,
attach, manage, or kill remote zmx sessions" describe the default: a pane
using local `amx` persistence around an SSH child. That default is now scoped
to local-amx panes.

A pane may instead declare `PersistenceOwner.remoteZmx`, naming a validated
session on the remote host. For such a pane, the remote host's backend owns
persistence: opening it runs `ssh <host> '<backend> attach <name>'` directly,
with no local daemon, no local agent-signaling side channel (§4 does not
apply), and no bridge preflight.

Which backend, and where, is resolved on the far side rather than declared.
The attach re-execs through `"$SHELL" -lc` and takes the first of `amx` on
`PATH`, `zmx` on `PATH`, or `amx` inside an installed `awesoMux.app`; nothing
found exits 127 with a message naming the problem. The login shell matters:
`ssh host cmd` runs a NON-login shell, so a `PATH` exported from `~/.zprofile`
or `~/.profile` is out of scope, which is why the original bare-`zmx` default
failed on every host tested. This replaces the per-pane executable path the
amendment originally carried, which was optional in name and mandatory in
practice (#235).

A `PATH` hit must resolve to an absolute path before it is `exec`'d. `command
-v` matches shell functions and aliases too, `exec` matches neither, and a
failed `exec` terminates a non-interactive shell — so accepting a bare match
would let a wrapper function in the very profile this sources abort every
remaining fallback and the diagnostic with it.

Known limits of the mechanism, all failing before any probe runs: a csh/tcsh
destination (csh takes `-l` only as its sole argument and has no `2>`
redirection), and a `$SHELL` that is unset or a `nologin` stub. Sourcing the
login profile also means whatever that profile prints — banners, MOTD — reaches
the pane ahead of the attach.

Restoring a pane that predates this change drops its recorded executable path
rather than honouring it, so a destination whose backend is reachable ONLY by
that path stops attaching, and one where discovery finds a DIFFERENT install
attaches that install's session of the same name instead. Accepted rather than
shimmed: remote-owned panes shipped days earlier in #222, and the path they
carried was the workaround for the bug this replaces.

Failure is visible and terminal — the disconnected overlay, never a fallback
to a local shell, another host, or a different persistence owner. Exit code 0
closes the pane, exactly as a local shell's `exit` does.

That status has to be recovered out of band, and the pane has to stop waiting
for a keypress to act on it. Neither is free:

- The pane runs with a command set rather than a login shell, so ghostty forces
  `wait_after_command` on
  ([ADR-0011](0011-persistent-session-daemon-command-bridge.md)) and the exit
  parks at "Press any key to close the terminal" instead of reaching the close
  callback. awesoMux therefore claims ghostty's child-exited action and drives
  the exit itself. It answers that claim synchronously — the return value
  decides whether ghostty paints its own screen — but enacts the teardown a
  main-actor turn later, because ghostty goes on using the surface after the
  action returns and the teardown frees it.
- libghostty's own child-exit code is 0 for every child on macOS, because
  ghostty spawns through `/usr/bin/login`, which does not propagate the child's
  status (`login -flpq "$USER" /bin/sh -c 'exit 7'` returns 0; ghostty's source
  records the symptom without naming the cause). A remote-owned pane also has
  no `amx` status channel to report into.

So the ssh client runs under a local `/bin/sh` that writes its exit status to a
per-pane file, which the exit decision reads and deletes. A file rather than an
in-band terminal report, deliberately: a write completes before the writer
exits, so the status is guaranteed readable when the child-exited action
arrives, whereas terminal bytes are parsed on libghostty's reader thread with no
ordering against that action at all. The file is also unambiguously ours — a far
host running its own shell integration emits OSC 133 reports that nothing
downstream could distinguish from a synthesized one — and it stays out of the
generic shell/agent completion pipeline that an in-band report would trigger on
its way through.

Exit code 0 closes the pane. Everything else — ssh's own 255, the discovery
script's 127, and a missing file — latches the disconnected overlay. Telling
those failures apart *from each other* in the overlay copy is
[#275](https://github.com/Interactive-Buffoonery/awesomux/issues/275) and is
not done here; this makes the signal available, nothing consumes it yet.

Accepted cost: a snapshot containing a `.remoteZmx` pane does not decode on a
pre-#214 build, and a snapshot fails to restore as a whole rather than per
pane — so downgrading loses the restore. Accepted pre-1.0; no compatibility
shim.

Remote-owned panes trade away every local-daemon extra: agent status and
sidebar agent state, path-bar cwd, `amx send`/`amx history` scripted
automation (see [`docs/amx-automation.md`](../amx-automation.md)), and
local-socket liveness probing on the quit path. App-relaunch reattach — the
remote zmx already holds the session when awesoMux next attaches — is the
promise; recovering a live drop automatically is not.
