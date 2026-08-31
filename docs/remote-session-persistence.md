# Remote session persistence

awesoMux can reconnect to a named terminal session on a remote Mac or Linux
host. The remote host owns the session, so its shell and running commands can
keep going after awesoMux quits or the SSH connection closes.

This setup uses `amx` or `zmx` on the remote host. It doesn't use the
[`awesomux-bridge-helper`](remote-linux-helper.md). The bridge helper provides
activity checks and file handoffs for regular managed SSH workspaces. It does
not provide session persistence.

## Before you connect

Install `amx` or `zmx` for the same user you use with SSH. awesoMux looks for a
backend in this order:

1. `amx` on the remote login shell's `PATH`
2. `zmx` on the remote login shell's `PATH`
3. `~/Applications/awesoMux.app/Contents/MacOS/amx`
4. `/Applications/awesoMux.app/Contents/MacOS/amx`

The first match wins. awesoMux does not upload or update this backend.

Check what the remote login shell can find:

```sh
remote_host=SSH_DESTINATION
ssh -t "$remote_host"
"$SHELL" -lc '
  command -v amx 2>/dev/null | grep "^/" && exit;
  command -v zmx 2>/dev/null | grep "^/" && exit;
  test -x "$HOME/Applications/awesoMux.app/Contents/MacOS/amx" &&
    printf "%s\n" "$HOME/Applications/awesoMux.app/Contents/MacOS/amx" && exit;
  test -x /Applications/awesoMux.app/Contents/MacOS/amx &&
    printf "%s\n" /Applications/awesoMux.app/Contents/MacOS/amx && exit;
  exit 1
'
```

Replace `SSH_DESTINATION` with the destination you pass to `ssh`. The command
must print an absolute path. Save that path for the recovery commands below. If
it prints nothing, install a backend or fix the `PATH` set by the remote user's
login shell.

## Install on macOS

You can install awesoMux in `/Applications` or `~/Applications` on the remote
Mac. awesoMux will find the `amx` binary inside the app.

You can also install upstream `zmx`:

```sh
brew install neurosnap/tap/zmx
```

See the [zmx installation options](https://github.com/neurosnap/zmx#install)
for Mise, Nix, release binaries, and source builds.

## Install on Linux

Upstream `zmx` provides static Linux binaries for `x86_64` and `aarch64`. See
the [zmx installation options](https://github.com/neurosnap/zmx#install) for
release binaries, Mise, Nix, distribution packages, and source builds. The
upstream binary is enough for remote session persistence. You do not need the
awesoMux fork.

Check the remote architecture first:

```sh
remote_host=SSH_DESTINATION
ssh "$remote_host" uname -m
```

Download the matching archive and `.sha256` file from the
[latest zmx release](https://github.com/neurosnap/zmx/releases/latest). Check
the download before extracting it:

```sh
version=RELEASE_VERSION
arch=REMOTE_ARCHITECTURE
archive="zmx-${version}-linux-${arch}.tar.gz"
expected="$(awk '{print $1}' "$archive.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
else
  printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c -
fi
tar -xzf "$archive"
```

Replace `RELEASE_VERSION` with the release version and `REMOTE_ARCHITECTURE`
with `x86_64` or `aarch64`.

Install the extracted binary on the remote host:

```sh
remote_host=SSH_DESTINATION
ssh "$remote_host" 'install -d -m 700 ~/.local/bin'
scp zmx "$remote_host":.local/bin/zmx.new
ssh "$remote_host" 'chmod 755 ~/.local/bin/zmx.new && mv ~/.local/bin/zmx.new ~/.local/bin/zmx'
```

Make sure `~/.local/bin` is on the remote login shell's `PATH`, then run the
[discovery check](#before-you-connect) again.

## Connect from awesoMux

1. Open **Connect via SSH**.
2. Enter the SSH destination.
3. Enter a **Remote session name**.
4. Connect.

The session name is its recovery name. awesoMux creates the session if it does
not exist and attaches to it if it does.

Session names can use up to 64 letters, numbers, dots, dashes, or underscores.
They cannot start with a dash or be `.` or `..`. Keep the name short because
the session name and socket directory must fit in a Unix socket path.

## Recover outside awesoMux

Connect as the same SSH user. Then check the backend and its socket directory:

```sh
remote_host=SSH_DESTINATION
ssh -t "$remote_host"
backend=/absolute/path/from/the-discovery-check
"$backend" version
"$backend" list
```

Replace the `backend` value with the path printed by the
[discovery check](#before-you-connect). `version` prints the socket directory.
`list` only shows sessions in that directory.

Attach to the session named in awesoMux:

```sh
session_name=SESSION_NAME
"$backend" attach "$session_name"
```

Closing the SSH connection detaches the client. It does not stop the session.

Kill a session only when you are done with it:

```sh
"$backend" list
session_name=SESSION_NAME
"$backend" kill "$session_name"
```

`kill` stops the shell and every command running in that session. Check the
session name and socket directory first.

### If the session is missing

`zmx` chooses its socket directory from the first available setting:

1. `ZMX_DIR`
2. `$XDG_RUNTIME_DIR/zmx`
3. `$TMPDIR/zmx-<uid>`
4. `/tmp/zmx-<uid>`

An empty `list` can mean there are no sessions, but it can also mean the shell
is using a different socket directory. Compare `"$backend" version` inside the
remote session and in the recovery shell.

If you set `ZMX_DIR`, use the same value for recovery:

```sh
ZMX_DIR=/path/from/zmx-version "$backend" list
ZMX_DIR=/path/from/zmx-version "$backend" attach "$session_name"
```

`ZMX_SESSION_PREFIX` changes every session name passed to the backend. If it is
set, `list` shows the full stored name while `attach` and `kill` add the prefix
again. To use the full name shown by `list`, unset the prefix for that command:

```sh
full_name=FULL_NAME_FROM_LIST
env -u ZMX_SESSION_PREFIX "$backend" attach "$full_name"
env -u ZMX_SESSION_PREFIX "$backend" kill "$full_name"
```

Inside an attached session, `$ZMX_SESSION` contains the full stored name:

```sh
printf '%s\n' "$ZMX_SESSION"
```

## What survives

A command running in the remote session survives:

- an ordinary SSH disconnection
- quitting awesoMux
- closing the MacBook lid or changing networks, once SSH disconnects

If the pane is still open, choose **Reconnect**. You can also reopen the
workspace later to attach to the same named session. awesoMux does not retry
automatically.

The session may not survive a remote host restart. An incompatible `zmx`
upgrade can also end existing sessions.

Remote-owned sessions do not have the features provided by the local `amx`
backend or Linux bridge helper. awesoMux cannot read their agent state, show
their current directory in the path bar, send scripted input, read history, or
check whether a command is running before closing the pane.

If SSH fails or the backend cannot attach, awesoMux shows the disconnected
remote pane. It does not open a local shell instead.

## Login shell limits

awesoMux asks the remote user's login shell to find the backend. This does not
work with csh or tcsh. It also fails when `$SHELL` is unset or points to a
`nologin` program.

Text printed by the remote login profile appears before the session attaches.
Keep non-interactive login setup quiet where possible.

## Verified setup

This flow was checked on August 31, 2026, with upstream `zmx` 0.7.1 on Debian
13, `aarch64`. A running timestamp loop survived a full awesoMux quit and a raw
OpenSSH `~.` disconnect. Direct `zmx attach` and awesoMux both reconnected to
the same session and process. Moving the `zmx` binary out of `PATH` produced a
visible remote-session error with no local-shell fallback. Restoring the binary
and choosing **Reconnect** attached to the original session again.

See [ADR-0023](adr/0023-remote-workspace-architecture.md) for the full remote
workspace design and its accepted limits.
