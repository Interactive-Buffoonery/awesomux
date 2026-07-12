# SSH Half-Open Sessions

After macOS sleep or a network change, an SSH pane can sit half-open until
OpenSSH notices the TCP connection is gone. awesoMux does not kill, restart,
probe, or otherwise mutate user SSH processes. Instead, wake and network path
changes mark known remote panes as possibly stale so the Path Bar can show a
quiet warning while SSH either recovers or reports failure.

awesoMux cannot force OpenSSH to detect a half-open TCP connection immediately.
Users who want faster disconnect detection can opt into SSH keepalives in their
own `~/.ssh/config`:

```sshconfig
Host *
  ServerAliveInterval 15
  ServerAliveCountMax 2
```

Do not write this automatically. Keepalive timing is user policy, not an
awesoMux default.
