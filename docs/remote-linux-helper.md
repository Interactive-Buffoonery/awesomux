# Linux remote helper

awesoMux installs a small helper on Linux hosts. The helper lets awesoMux:

- show command activity in the sidebar
- paste images and Markdown files into the remote session
- warn you before closing a session with a running command

awesoMux installs the helper for you. You only need the manual steps below for
development builds or if the automatic install isn't available.

The helper only works in a managed SSH workspace. It doesn't work when you type
`ssh` in a regular terminal pane. It also doesn't run when you enter a
**Remote session name**, because that session connects straight to `amx` or
`zmx` on the Linux host.

## Install the helper

1. Use **Connect via SSH** to start a new connection. To convert an open SSH
   connection, use **Make This Workspace Managed**.
2. Leave **Remote session name** empty.
3. Connect. awesoMux checks for the helper at
   `~/.awesomux/bin/awesomux-bridge-helper`.
4. If the helper is missing or out of date, awesoMux shows what it will install
   and where it will install it. Choose **Install Helper** or **Update Helper**.

awesoMux detects the Linux architecture, downloads the helper that matches your
app version, checks its SHA-256 checksum, and copies it over the SSH connection.
The Linux host doesn't need internet access.

Choose **Continue Without Helper** if you don't want to install it. The SSH
session will still open, but the features listed above won't work. awesoMux will
offer the install again the next time you connect.

## What gets installed

The helper runs as your SSH user. It doesn't use `sudo` or install a system
package.

```text
~/.awesomux/                         mode 0700
~/.awesomux/bin/                     mode 0700
~/.awesomux/bin/awesomux-bridge-helper
```

Before installing, awesoMux checks that these paths belong to your SSH user and
aren't symbolic links. Both directories must have `0700` permissions.

awesoMux writes the download to a temporary file first. It checks the file size,
checksum, and supported features before replacing an installed helper. If a
check fails, awesoMux removes the temporary file and keeps the old helper.

OpenSSH still handles your SSH config, keys, and other credentials. awesoMux
doesn't copy or store them.

## Supported Linux systems

awesoMux provides static `x86_64` and `aarch64` binaries. They don't depend on
glibc or other shared libraries.

The installer expects standard Linux tools in `/bin` and `/usr/bin`: `sh`,
`uname`, `id`, `stat`, `mktemp`, `cat`, `chmod`, `grep`, and `mv`. It also needs
either `/usr/bin/sha256sum` or `/usr/bin/shasum`.

## Check the installed helper

Run:

```sh
ssh <host> '~/.awesomux/bin/awesomux-bridge-helper --version'
```

The output should include all three lines:

```text
awesomux-bridge-v1
awesomux-handoff-v1
awesomux-liveness-v1
```

awesoMux runs this check when it opens a managed SSH workspace. If one of these
features is missing, the app offers to update the helper.

## Troubleshooting

### No install prompt appears

Make sure you're using **Connect via SSH** or **Make This Workspace Managed**.
Leave **Remote session name** empty. Typing `ssh <host>` in a terminal doesn't
start the helper setup.

### The helper folder isn't private

Check the existing files and folders:

```sh
ssh <host> 'ls -ld ~/.awesomux ~/.awesomux/bin ~/.awesomux/bin/awesomux-bridge-helper 2>/dev/null'
```

`~/.awesomux` and `~/.awesomux/bin` must be real directories owned by your SSH
user. Both must have `0700` permissions. If the helper already exists, it must
be a regular file owned by the same user.

Fix the file type, owner, or permissions and reconnect. awesoMux won't replace
files in a directory other users can access.

### The download fails

The app downloads the helper from the GitHub release that matches the version
shown in **About awesoMux**. Local and nightly builds may not have matching
Linux files. Use a matching CI build or build the helper from the same checkout.

### The SSH session opens without helper features

This happens when you decline the install or setup fails. The terminal stays
usable. Fix the reported problem and reconnect to try again.

## Install manually

Use these steps for local builds, CI builds, or recovery:

1. Check the Linux architecture:

   ```sh
   ssh <host> 'uname -m'
   ```

2. Download `awesomux-bridge-helper-linux-<arch>` and its `.sha256` file from
   the [GitHub release](https://github.com/Interactive-Buffoonery/awesomux/releases)
   that matches your awesoMux version. You can also build both files from the
   same source checkout.

3. Check the download:

   ```sh
   # Linux
   sha256sum -c awesomux-bridge-helper-linux-<arch>.sha256

   # macOS
   shasum -a 256 -c awesomux-bridge-helper-linux-<arch>.sha256
   ```

4. Copy the helper to the Linux host:

   ```sh
   scp awesomux-bridge-helper-linux-<arch> <host>:/tmp/awesomux-bridge-helper
   ssh <host> 'install -d -m 700 ~/.awesomux && install -d -m 700 ~/.awesomux/bin && \
     install -m 700 /tmp/awesomux-bridge-helper ~/.awesomux/bin/awesomux-bridge-helper && \
     rm /tmp/awesomux-bridge-helper'
   ```

5. Run the [check command](#check-the-installed-helper).

## Check foreground activity by hand

awesoMux runs this check before closing a remote session. You can run it by hand
if you're debugging the helper:

```sh
~/.awesomux/bin/awesomux-bridge-helper foreground-liveness --session <terminalSessionID>
```

The command prints one JSON object. It reports whether the shell is idle, has a
background process, is running a command, can't be checked, or is gone. Missing
or conflicting information is never reported as idle.

The helper finds session processes through the `AWESOMUX_BRIDGE_SESSION`
environment variable. If Linux blocks access to a process environment, the
helper ignores that process instead of assigning it to the wrong session.

## Build from source

Run:

```sh
./script/build_linux_helper.sh
```

The script builds both Linux architectures with the Swift Static Linux SDK. It
needs the swift.org toolchain that matches `.swift-version` - the Xcode
toolchain can't use this SDK. The binaries and checksum files are written to
`dist/linux-helper/`.

## CI and releases

`.github/workflows/linux-helper.yml` runs the Linux tests, builds both static
binaries, and tests file handoff through a real SSH server. Tagged releases
include both binaries and their checksum files. Nightly releases only include
the macOS app.
