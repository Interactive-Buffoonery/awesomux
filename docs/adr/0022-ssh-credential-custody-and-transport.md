# ADR-0022: awesoMux is never the custody point for SSH credentials

## Status
Accepted

## Context
The remote-workgroups feature (`amx ssh`) spawns `ssh`/`scp` on the user's
behalf. That makes it tempting to "help" with authentication — remember a
password, prompt for a passphrase, hold a key. Doing so would make awesoMux
responsible for the security of a user's entire SSH surface. We refuse that
responsibility.

## Decision
awesoMux MUST NOT store, prompt for, cache, transmit, or otherwise take
custody of SSH passwords, key passphrases, or private keys. All authentication
is delegated 100% to the user's existing `ssh-agent`, macOS keychain, and
`~/.ssh/config`. If a host needs a secret, that transaction happens inside the
terminal between the user and `ssh`, exactly as in any terminal — awesoMux
neither sees nor persists it.

awesoMux injects only *transport* configuration it fully owns: connection
multiplexing (`ControlMaster`/`ControlPath`/`ControlPersist`) and keepalive
(`ServerAliveInterval`). These carry no secrets. It additionally forces
`ForwardAgent=no` on managed panes so a user's `~/.ssh/config ForwardAgent yes`
cannot silently expose the local agent to remote hosts through our automation;
agent forwarding remains a deliberate opt-in for a later decision, never a
default.

## Consequences
- Key/agent auth is the supported path. A host that would prompt for a
  password prompts inside the pane; automated `scp` to such a host is
  best-effort and may fail if it needs interaction. This is acceptable.
- The only future path that could change this is hardware-backed key material
  the OS custodies for us (Secure Enclave keys whose private half never leaves
  the enclave; awesoMux holds only a handle). That requires its own ADR and
  threat model. It must not be back-doored via "temporary" credential handling.
