# ADR-0023: Remote workspace architecture — awesoMux composes with SSH

## Status

Accepted

Some sub-decisions are explicitly delegated to open design issues and marked as
such inline (host-profile storage details → INT-696; remote agent bridge wire
format → INT-698). The boundaries and constraints below are decided; only those
named wire/storage details are deferred.

## Context

awesoMux runs a persistent local session daemon behind an `amx` seam
([ADR-0011](0011-persistent-session-daemon-command-bridge.md)): each terminal
surface's child is `amx attach <id>` rather than a login shell, so the daemon —
not the app — owns the durable session. The make-or-break constraint from that
ADR still holds: `ghostty_surface_new()` always forks its own child and exposes
no field to attach an existing PTY/fd, so *any* persistence — local or remote —
has to be a command-bridge, never a direct socket adopt.

Remote work means a user wants a Workspace Group whose panes live on another
host reached over SSH. The shipped foundation (PR #494, PR #498) adds a declared
`RemoteTarget` to a group and spawns the bridge with an `ssh` tail. This ADR
records how the moving parts — local `amx`, remote `zmx`, SSH host profiles,
target-side setup, file handoff, and the remote agent bridge — compose, and
which compositions are explicitly unsupported. It also records why the existing
local agent side channel does not cross SSH.

Related prior decisions:

- [ADR-0011](0011-persistent-session-daemon-command-bridge.md) — the `amx` seam,
  the command-bridge shape, and the local daemon lifecycle this builds on.
- [ADR-0021](0021-remote-markdown-uses-submitted-ssh-target.md) — Remote
  Markdown fetches over a submitted `ssh` target and anticipated that "fuller
  SSH integration should own connection identity directly." `RemoteTarget` is
  that connection identity.
- [ADR-0022](0022-ssh-credential-custody-and-transport.md) — awesoMux never
  custodies SSH credentials and injects only transport config (`ControlMaster`,
  keepalive, `ForwardAgent=no`). This ADR inherits that boundary wholesale.

## Decision

### 1. awesoMux composes with SSH; zmx Unix sockets stay local

zmx/`amx` daemons speak over local Unix-domain sockets only. awesoMux does **not**
make those sockets network- or remote-aware, and does not tunnel a zmx control
protocol over TCP. "Remoteness" is supplied by the SSH transport, not by a
remote-aware socket protocol. To reach a persistent session on another host you
SSH into that host and run *its* session tooling there — exactly the workflow
zmx documents (`RemoteCommand zmx attach …` in `~/.ssh/config`). This keeps
awesoMux out of the business of authenticating, encrypting, and multiplexing a
bespoke remote protocol; SSH already does all three.

### 2. Persistence has one owner per pane: local `amx` **or** remote `zmx`, never both

A remote pane can place its durable session in one of two spots, and the two are
mutually exclusive:

- **Local `amx` persists a remote shell (shipped).** The surface runs the local
  command-bridge whose child is `ssh <target>`, i.e.
  `amx attach <id> ssh -o … <user@host>`. The **local** daemon owns the session;
  its process is the SSH connection to a plain remote login shell. This survives
  local app quit (the daemon and its SSH connection outlive the app) and works
  against any Unix host with `sshd` and a shell — no remote install required.
- **Remote `zmx` persists (bypasses local `amx`).** The pane's surface runs
  `ssh <target>` directly — optionally with the host's `RemoteCommand zmx attach
  <remote-id>` — and the **remote's own** zmx daemon owns persistence on that
  host. A remote-zmx pane does **not** also run a local `amx attach` around the
  SSH child: **remote zmx panes bypass local `amx`.** The local app is a thin
  SSH client to the remote daemon.

Which owner applies is a property of the target mode (§4) and the pane's
configuration, not something the two layers negotiate at runtime.

### 3. The doubly-nested path is unsupported

`local amx  ──▶  ssh  ──▶  remote zmx` (local `amx attach` wrapping `ssh` wrapping
a remote `zmx attach`) is **not supported**. Two persistence daemons in series
means two independent VT snapshot/replay layers, two scrollback buffers, doubled
and ambiguous resize authority, and a session-end reason that cannot be
attributed to one layer (which daemon died? which detached?). Pick one
persistence owner per pane. The shipped path is local-`amx`-persists-remote-shell
(§2, first bullet); the remote-zmx path (second bullet) is the alternative, not
an addition on top.

### 4. Two target modes

- **Managed Mac target.** awesoMux is installed on the target Mac. Because it is
  present there, it can install and configure helpers on the target — the `amx`
  binary, the agent hook, shell integration — and the remote side can run its own
  `amx`/`zmx`. This is the path that enables remote-side persistence (§2, second
  bullet) and a remote agent bridge (§6).
- **Unmanaged Unix target.** awesoMux connects over SSH and uses whatever already
  exists on the remote (a login shell, existing tools). It installs nothing and
  assumes nothing beyond `sshd` + a shell. This is the shipped default and maps
  onto local-`amx`-persists-remote-shell (§2, first bullet). Linux and other
  non-macOS hosts are always unmanaged in the "no full app" sense (§ Limitations):
  a helper/CLI install path, never the macOS app.

### 5. Security boundaries

- **Host aliases / `RemoteTarget`.** A `RemoteTarget` is `{user, host}` parsed
  permissively from `user@host` (split on the last `@`; user optional). It is
  **declared configuration, not a secret** — persisted in the workspace snapshot
  as group state, distinct from the disposable, title-derived
  `TerminalPane.remoteHost` detection signal ([ADR-0021](0021-remote-markdown-uses-submitted-ssh-target.md)).
  awesoMux does not resolve, validate, or expand the host; `ssh` and the user's
  `~/.ssh/config` are the sole authority on what it means and whether it
  resolves, so SSH config aliases work without an awesoMux host-mapping UI. The
  storage layout for richer host profiles (ports, proxies, per-host options
  beyond `{user, host}`) is **delegated to INT-696**; this ADR fixes only that
  profiles are config, never credentials.
- **Credentials and transport.** Inherited unchanged from
  [ADR-0022](0022-ssh-credential-custody-and-transport.md): awesoMux never
  stores, prompts for, caches, or transmits passwords, passphrases, or keys. It
  injects only transport config it fully owns — connection multiplexing
  (`ControlMaster=auto`, a stable per-profile `ControlPath` in the verified
  owner-only `~/.awesomux/ssh*` directory, `ControlPersist=60`), keepalive
  (`ServerAliveInterval=15`) — and forces
  `ForwardAgent=no` on managed panes so a user's `ForwardAgent yes` cannot
  silently expose the local agent to remote hosts through our automation. The
  `ControlPath` directory is lstat-verified as a real owner-only directory and
  falls back to a short `mkdtemp` directory on any custody failure. The stable
  primary path is required so forwards borrowed by a persistent zmx session
  survive an app relaunch; both paths fit `sockaddr_un`, including OpenSSH's
  pre-rename temp suffix (INT-766, INT-698 live smoke).
- **Setup commands and helper installation.** Only on a **managed** target does
  awesoMux run setup or install helpers, and only explicitly — least privilege,
  no silent privilege escalation, no implicit `sudo`. On an **unmanaged** target
  awesoMux installs nothing and executes no setup; it uses the tools already
  present. A remote group whose attach command cannot be built (bundled `amx`
  missing, or the command bridge globally disabled) resolves to
  `.remoteUnavailable` and surfaces a **visible error**, never a local shell — a
  local shell masquerading as the remote host is the ADR-0022 trust violation
  and would invite typing secrets into the wrong machine.
- **File transfer.** File handoff (`scp`/`sftp`) rides the same transport config
  and the same `ForwardAgent=no` posture; no credential custody. It is
  best-effort: a host that needs interactive authentication for every new
  connection may fail a non-interactive transfer even when the interactive pane
  works (the ADR-0021 constraint, generalized).
- **Remote agent bridge messages.** Agent state signaling from a remote pane must
  travel over the SSH transport back to the app and be authenticated the way the
  local status channel is (a forgery-guard token like `AMX_STATUS_TOKEN`,
  per-attach, so a stale or mis-routed remote write is rejected). It must **not**
  reuse the local file-drop side channel (§6). The concrete wire format and
  transport for remote agent messages are **delegated to INT-698**; this ADR
  fixes only that they need their own authenticated transport and cannot be the
  local JSONL path.

### 6. The local agent side channel does not cross SSH

awesoMux's agent runtime side channel is a **local file drop**: each pane exports
`AWESOMUX_AGENT_EVENT_FILE` pointing at a JSONL file on the **local** machine,
which the local app watches with `kqueue`. The reader opens that path with
`O_NOFOLLOW` and verifies the descriptor is a regular file owned by the current
**local** effective user (see `docs/agent-runtime-side-channel.md`). None of that
survives SSH:

- The path names a file on the local filesystem. A process on the remote host
  cannot open it, and even if the env var propagated through `ssh`, the remote
  agent's writes would land in a file on the **remote** filesystem that the local
  `kqueue` watcher never observes.
- The owner/`O_NOFOLLOW` checks are scoped to the local uid and offer no meaning
  across a trust and filesystem boundary.

So the file-drop path is valid only for local (including local-`amx`-persists-
remote-shell, where the agent still runs against a local surface's env) panes. A
remote agent running *on the target* needs a distinct transport that carries
events back over the SSH connection (§5, last bullet; delegated to INT-698). The
`amx`/`zmx` out-of-band signals (cwd, session-end reason) already ride IPC over
the daemon's local socket rather than the PTY stream and are similarly a local
mechanism; a remote target's out-of-band signals must be re-sourced over SSH, not
assumed to arrive on the local socket.

## Consequences

- The shipped remote path (local `amx` persisting `ssh <target>` to an unmanaged
  Unix host) requires nothing on the remote but `sshd` + a shell, and inherits
  the full ADR-0011 robustness work (respawn-on-detach, error latching, GC
  scoping) for free because it *is* the local bridge with an `ssh` tail.
- Remote panes fail loud, never silently local: a broken remote group is a
  visible error, and a deliberate remote `exit` closes the pane while a dropped
  connection (ssh 255) or unknown end reason surfaces an error to reconnect from
  rather than auth-looping (`BridgeSessionEndPolicy`, INT-769).
- Remote-side persistence and a remote agent bridge are gated on the managed-Mac
  target mode and on INT-696/INT-698; until those land, remote groups get local
  persistence of a remote shell and no agent-native chrome from the far side.
- Choosing "compose with SSH" means awesoMux never owns a remote wire protocol,
  its auth, or its crypto — a deliberately smaller surface than a remote-aware
  zmx socket would have been.

## Limitations

- **The app stays macOS-only.** Non-macOS targets (Linux, BSD) are reached over
  SSH and, where they need awesoMux helpers, use a helper/CLI install path — not
  the full macOS app. "Managed" in the full-app sense is a Mac-target concept.
- **No direct remote PTY/socket attach.** The public libghostty API exposes no
  fd-attach ([ADR-0011](0011-persistent-session-daemon-command-bridge.md)), so a
  remote session is reached only by spawning `ssh` as the surface's child (the
  command-bridge shape), never by adopting a remote PTY or a remote socket
  directly.
- **Persistence survives local app quit, not necessarily remote reboot.** The
  durable session lives in a daemon's RAM — the local `amx` daemon (shipped) or a
  remote `zmx` daemon (managed) — so it outlives the local app but not a reboot
  of the host that owns it. This is the same reboot ceiling ADR-0011 records for
  local sessions, now on whichever side owns persistence.
