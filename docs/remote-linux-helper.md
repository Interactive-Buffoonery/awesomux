# Linux bridge helper

Static Linux builds of `awesoMuxBridgeHelper` let a declared SSH pane with a
Linux destination receive file handoffs (one clipboard image or copied
Markdown file per paste). The macOS app needs no configuration: it probes
`~/.awesomux/bin/awesomux-bridge-helper --version` over SSH and uses the
helper when both `awesomux-bridge-v1` and `awesomux-handoff-v1` are
advertised. Newer helpers independently advertise `awesomux-liveness-v1` for
remote foreground-process inspection; its absence does not affect bridge or
handoff compatibility.

## Supported targets

Any Linux distribution with a reasonably modern kernel on `x86_64` or
`aarch64`. The binaries are fully static (musl); they have no runtime
dependencies and no glibc version floor.

## Install

When a managed SSH workspace connects to a supported Linux destination without
the current helper, awesoMux offers to install it for that SSH account. The app
downloads the architecture-specific asset from the GitHub release matching the
running app, verifies the published SHA-256 checksum locally, then streams the
verified bytes over the existing SSH connection. Installation uses
`~/.awesomux/bin/awesomux-bridge-helper`, requires no administrator access, and
does not prevent an ordinary SSH connection when declined or unavailable.

Development builds and operators who prefer an explicit setup can install
manually:

1. Download `awesomux-bridge-helper-linux-<arch>` and its `.sha256` from the
   [latest release](https://github.com/Interactive-Buffoonery/awesomux/releases),
   or build from source (below).
2. Verify: `sha256sum -c awesomux-bridge-helper-linux-<arch>.sha256`
3. Copy and install on the destination:

   ```sh
   scp awesomux-bridge-helper-linux-<arch> <host>:/tmp/awesomux-bridge-helper
   ssh <host> 'install -d -m 700 ~/.awesomux && install -d -m 700 ~/.awesomux/bin && \
     install -m 755 /tmp/awesomux-bridge-helper ~/.awesomux/bin/awesomux-bridge-helper && \
     rm /tmp/awesomux-bridge-helper'
   ```

   `~/.awesomux` and `~/.awesomux/bin` MUST be mode `0700` and owned by the SSH
   user — the helper validates directory custody and refuses
   group/world-accessible paths.
4. Check: `ssh <host> '~/.awesomux/bin/awesomux-bridge-helper --version'`
   must print `awesomux-bridge-v1` and `awesomux-handoff-v1`. A helper that also
   prints `awesomux-liveness-v1` supports the optional foreground-liveness
   probe.

## Foreground liveness

The optional probe reads the Linux process tree associated with one terminal
session and writes one bounded JSON object:

```sh
~/.awesomux/bin/awesomux-bridge-helper foreground-liveness --session <terminalSessionID>
```

The helper can associate a process with the requested session only after reading
its `AWESOMUX_BRIDGE_SESSION` environment entry. If Linux denies that read, the
process is ignored because marking every unreadable same-user process as a match
would make unrelated protected processes contaminate every pane's result.
Evidence already associated with the requested session still fails closed as
`indeterminate` if the process changes or disappears while it is sampled.

The report distinguishes an idle shell, a shell with background descendants,
a foreground command, indeterminate evidence, and a session that is gone. The
probe never treats incomplete or contradictory process evidence as idle.

If no published release matches a development build, install its CI artifact or
a source build manually before testing managed bridge features.

## Build from source

`./script/build_linux_helper.sh` cross-compiles both architectures with the
Swift Static Linux SDK (pin documented in the script; matches
`.swift-version`). Requires a swift.org toolchain — Xcode's cannot consume
the Static Linux SDK. Output lands in `dist/linux-helper/`.

## CI

`.github/workflows/linux-helper.yml` runs the portable test targets under
Glibc on `ubuntu-24.04`, cross-compiles both static binaries with the Swift
Static Linux SDK, and drives an end-to-end SSH smoke
(`script/ci/linux_handoff_smoke.sh`) against a real sshd on every change to
the helper's dependency graph. The Static Linux SDK ships no Testing module,
so the cross-compiled binaries can't run the unit suite directly — the sshd
smoke is what exercises Musl-linked behavior on the real static binary.
