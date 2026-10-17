# SSH Half-Open Sessions

After macOS sleep or a network change, an SSH pane can sit half-open until
OpenSSH notices the TCP connection is gone. awesoMux does not kill, restart,
or otherwise mutate user SSH processes. Wake and network path changes revoke
cached remote-pane liveness evidence and pending file reads originating from
those panes. They preserve the connection health: a machine-wide signal does not establish that a specific
SSH connection has failed. Existing SSH disconnect and reconnect observations
continue to drive the Path Bar connection status.

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

## Repeatable connectivity check

With an existing SSH alias that supports noninteractive access:

```sh
python3 script/verify-ssh-connectivity.py --host example-host --output /tmp/ssh-connectivity.log
```

The diagnostic compiles the actual core and connectivity services in a temporary
package and keeps one real SSH process delivering output across a synthetic
connectivity signal. It checks titleless responses, repeated invalidation,
remote file-read revocation, and separation of liveness probes across events.
It writes an inspectable log with source fingerprints. It does not change the
network or replace native UI verification or the required repository preflight.
