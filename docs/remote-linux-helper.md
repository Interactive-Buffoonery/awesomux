# Linux bridge helper

Static Linux builds of `awesoMuxBridgeHelper` let a declared SSH pane with a
Linux destination receive file handoffs (one clipboard image or copied
Markdown file per paste). The macOS app needs no configuration: it probes
`~/.awesomux/bin/awesomux-bridge-helper --version` over SSH and uses the
helper when both `awesomux-bridge-v1` and `awesomux-handoff-v1` are
advertised.

## Supported targets

Any Linux distribution with a reasonably modern kernel on `x86_64` or
`aarch64`. The binaries are fully static (musl); they have no runtime
dependencies and no glibc version floor.

## Install

The app's automatic helper installation is macOS-only; on Linux
destinations install manually:

1. Download `awesomux-bridge-helper-linux-<arch>` and its `.sha256` from the
   [latest release](https://github.com/Interactive-Buffoonery/awesomux/releases),
   or build from source (below).
2. Verify: `sha256sum -c awesomux-bridge-helper-linux-<arch>.sha256`
3. Copy and install on the destination:

   ```sh
   scp awesomux-bridge-helper-linux-<arch> <host>:/tmp/awesomux-bridge-helper
   ssh <host> 'install -d -m 700 ~/.awesomux && install -d -m 755 ~/.awesomux/bin && \
     install -m 755 /tmp/awesomux-bridge-helper ~/.awesomux/bin/awesomux-bridge-helper && \
     rm /tmp/awesomux-bridge-helper'
   ```

   `~/.awesomux` MUST be mode `0700` and owned by the SSH user — the helper
   validates directory custody and refuses group/world-accessible paths.
4. Check: `ssh <host> '~/.awesomux/bin/awesomux-bridge-helper --version'`
   must print `awesomux-bridge-v1` and `awesomux-handoff-v1`.

If the helper is missing when you paste, the app's install prompt reports
the platform as unsupported — that alert is about automatic installation
only; a manual install per this page makes the same paste work.

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
