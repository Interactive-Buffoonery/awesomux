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
