# Linux bridge helper design

Issue: [#87 — Support Linux destinations for remote file handoff](https://github.com/Interactive-Buffoonery/awesomux/issues/87)
Date: 2026-07-22
Status: approved

## Goal

Let a macOS awesoMux client paste one clipboard image or copied Markdown file
into a declared SSH pane whose destination is Linux. The macOS helper path
(#5) works end to end; Linux destinations fail only because the built
`awesoMuxBridgeHelper` is a Mach-O executable. This design produces a
Linux-native `awesomux-bridge-helper` from the same Swift sources, preserving
the `awesomux-handoff-v1` command and receipt contract byte for byte.

## Verified constraints

- **The macOS client needs zero changes.** `RemoteHandoff` probes the remote
  helper with `--version` first (`RemoteHelperInstaller.capability`). A helper
  that is present at `~/.awesomux/bin/awesomux-bridge-helper` and advertises
  both `awesomux-bridge-v1` and `awesomux-handoff-v1` returns `.supported`,
  which skips the Darwin/arm64-gated platform probe and installer entirely.
  The platform gate only fires on the auto-install path, and automatic Linux
  installation is an explicit non-goal of #87.
- The helper's only `AwesoMuxCore` usage is the bridge protocol surface:
  `BridgeEnvelope`, `BridgeStateFile`, `BridgeFrameReader`, `BridgeHandshake`,
  `BridgeEpochPolicy`, `BridgePendingRequestMap`, `BridgeTunables`, the
  permission message types, and `TerminalSessionID`. Those files import only
  Foundation and `UnicodeHygiene`.
- The support module's Darwin usage is POSIX except one call:
  `renameatx_np(RENAME_EXCL)` for atomic no-overwrite publication.

## Design

### 1. Target extraction: `AwesoMuxBridgeProtocol`

New SPM target holding the wire contract both ends of the bridge speak:

- Moves `Sources/AwesoMuxCore/Services/Bridge/*` (7 files) and
  `Sources/AwesoMuxCore/Models/TerminalSessionID.swift` to
  `Sources/AwesoMuxBridgeProtocol/`.
- Depends only on `UnicodeHygiene`.
- `AwesoMuxCore` adds a dependency on it; call sites gain explicit
  `import AwesoMuxBridgeProtocol` statements (mechanical; no `@_exported`
  shims).
- `AwesoMuxBridgeHelperSupport` and the `awesoMuxBridgeHelper` executable
  replace their `AwesoMuxCore` dependency with `AwesoMuxBridgeProtocol`,
  making the helper's dependency graph Foundation + Dispatch +
  `AwesoMuxBridgeProtocol` + `UnicodeHygiene` — fully cross-compilable.
- One target, not several: the whole set has a single reason to change
  (protocol revision) and both consumers need all of it.

No behavior change on macOS. Bridge protocol tests move with their types where
they exist; helper tests keep their current target.

### 2. Platform seams in `AwesoMuxBridgeHelperSupport`

The three files that `import Darwin` (`HandoffReceiver`, `HelperConnection`,
`BridgeStateFileCustody`) gain
`#if canImport(Darwin) … #elseif canImport(Glibc)` seams:

- `renameatx_np(fd, a, fd, b, RENAME_EXCL)` →
  `renameat2(fd, a, fd, b, RENAME_NOREPLACE)` on Linux. If the C library in
  the pinned Static Linux SDK does not expose the `renameat2` wrapper, call
  `syscall(SYS_renameat2, …)` directly — the kernel interface is stable.
- `Darwin.signal` / `sig_t` → `Glibc.signal` / the Glibc handler type in
  `HandoffSignalCleanup`. Dispatch signal sources work unchanged
  (swift-corelibs-libdispatch).
- Everything else (`open`/`openat` with `O_NOFOLLOW|O_DIRECTORY|O_CLOEXEC`,
  `mkdirat`, `fstat`, `fsync`, `unlinkat`, `read`/`write` loops) compiles on
  both platforms as-is.

Security semantics preserved verbatim on both platforms: 10 MB cap, exact-byte
streaming with trailing-byte rejection, owner-only `0700`/`0600` custody
verified on descriptors (not paths), symlink rejection, unique names, atomic
no-overwrite publication, temp-file cleanup on every failure path including
signals.

### 3. Build and release

- `script/build_linux_helper.sh`: cross-compiles
  `swift build --product awesoMuxBridgeHelper --swift-sdk <triple>` for
  `x86_64-swift-linux-musl` and `aarch64-swift-linux-musl`, producing fully
  static binaries with no runtime dependencies on the target. The Static
  Linux SDK version is pinned to match the `.swift-version` toolchain
  (currently 6.3.3), checked and documented per `docs/toolchain.md`
  conventions.
- The release workflow gains a job that builds both arches and attaches
  `awesomux-bridge-helper-linux-x86_64` and
  `awesomux-bridge-helper-linux-aarch64` plus SHA-256 checksums to the GitHub
  release.
- Static musl linking makes the supported-distribution statement simply:
  any Linux with a reasonably modern kernel on x86_64 or aarch64.

### 4. CI

One new workflow, path-filtered to the helper dependency graph
(`Sources/AwesoMuxBridgeProtocol/`, `Sources/AwesoMuxBridgeHelperSupport/`,
`Sources/awesoMuxBridgeHelper/`, `Sources/UnicodeHygiene/`, the build script,
and the workflow itself), running on an Ubuntu runner:

1. **Cross-compile** both static binaries with the pinned SDK.
2. **Linux unit coverage**: run `AwesoMuxBridgeHelperSupportTests` (and the
   bridge protocol tests) with the Linux Swift toolchain. The existing
   custody / early-EOF / oversize / collision / symlink suite becomes the
   required Linux receiver coverage. Test-only Darwin references get the same
   seam treatment; `AwesoMuxTestSupport` is expected to be portable for the
   subset these tests use (verify during planning).
3. **SSH end-to-end smoke**: start `sshd` in a container, install the freshly
   built static binary at `~/.awesomux/bin/awesomux-bridge-helper`, then over
   a real ssh connection assert:
   - `--version` prints `awesomux-bridge-v1` and `awesomux-handoff-v1`;
   - a piped `receive-handoff` stores the file under
     `~/.awesomux/handoffs/<session-id>/` with `0700` directories, a `0600`
     file, and returns the bounded JSON receipt;
   - one failure case (early EOF or oversize) exits nonzero and leaves no
     temporary or final file behind.

### 5. Documentation

New `docs/remote-linux-helper.md`:

- Supported architectures and the static-linking distribution statement.
- Manual installation: download from the release (or build via
  `script/build_linux_helper.sh`), `scp` to the destination, install at
  `~/.awesomux/bin/awesomux-bridge-helper`, `chmod 0755`, verify with
  `--version`.
- Note that when the helper is absent on a Linux destination, the app's
  auto-install flow reports the platform as unsupported — install manually
  per this document. (Adjusting that alert copy to point here is optional
  follow-up, not in scope.)
- Cross-link from the remote-workspace docs (ADR 0023 area) and README as
  appropriate.

## Testing summary

- Existing helper-support suite runs on macOS (as today) and Linux (new CI),
  covering the acceptance-criteria failure modes on the Linux receiver.
- New unit coverage only where Linux-specific behavior diverges (the
  `renameat2` publish path collision behavior).
- The sshd-container job is the end-to-end acceptance check.
- macOS behavior is regression-guarded by the existing full test suite; the
  extraction is a move, not a rewrite.

## Out of scope (per issue non-goals)

- Automatic remote helper installation for Linux destinations.
- Porting the awesoMux GUI to Linux.
- Password/key/passphrase management changes.
- Batches, drag-and-drop, arbitrary file types, or synchronization.
