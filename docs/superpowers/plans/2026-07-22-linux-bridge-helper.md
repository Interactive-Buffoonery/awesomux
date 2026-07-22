# Linux Bridge Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Linux-native `awesomux-bridge-helper` (static musl, x86_64 + aarch64) from the existing Swift sources so declared SSH panes with Linux destinations can receive file handoffs, per [#87](https://github.com/Interactive-Buffoonery/awesomux/issues/87) and the approved spec (`docs/superpowers/specs/2026-07-22-linux-bridge-helper-design.md`).

**Architecture:** Extract the bridge wire-contract types out of `AwesoMuxCore` into a new portable `AwesoMuxBridgeProtocol` target; add Darwin/Glibc/Musl seams to `AwesoMuxBridgeHelperSupport`; give `Package.swift` an `#if os(Linux)` portable-subset branch; cross-compile with the Swift Static Linux SDK; add a Linux CI workflow (unit tests + cross-compile + sshd-container smoke) and wire artifacts into the release workflow.

**Tech Stack:** Swift 6.3.3 (pinned via `.swift-version`), SwiftPM, Swift Static Linux SDK (musl), GitHub Actions `ubuntu-24.04` + `swift:6.3.3-noble` container, Docker for the sshd smoke.

## Global Constraints

- Swift toolchain pin: `6.3.3` (`.swift-version`); the Static Linux SDK pin MUST match it and bump with it (`docs/toolchain.md`).
- Conventional Commits: `<type>(<scope>): <lowercase imperative>`, subject ≤72 chars.
- Never run a repo-wide formatter; `script/format.sh` only on intentionally changed Swift files.
- macOS behavior must be bit-for-bit unchanged: full existing test suite green after every task (`./script/swift-test.sh`).
- Comments explain *why*, never narrate code. No backwards-compat shims (pre-1.0).
- Security semantics preserved verbatim on both platforms: 10 MB cap, exact-byte streaming + trailing-byte rejection, `0700`/`0600` owner-only custody validated on descriptors, symlink rejection, unique names, atomic no-overwrite publication, temp cleanup on every failure path.
- The helper's installed name/path contract: `~/.awesomux/bin/awesomux-bridge-helper`; `--version` prints `awesomux-bridge-v1` and `awesomux-handoff-v1`, one per line.
- Do not touch `vendor/ghostty` or `vendor/zmx`.
- Branch: `issue/87-linux-bridge-helper` (exists). All work lands there; PR to `main` at the end.

---

### Task 1: Extract `AwesoMuxBridgeProtocol` target

**Files:**
- Create: `Sources/AwesoMuxBridgeProtocol/` (moved files below)
- Create: `Sources/AwesoMuxCore/Models/TerminalBackendMetadata.swift` (split out)
- Move: `Sources/AwesoMuxCore/Services/Bridge/{BridgeEnvelope,BridgeEpochPolicy,BridgeFrameReader,BridgeHandshake,BridgePendingRequestMap,BridgeStateFile,BridgeTunables}.swift` → `Sources/AwesoMuxBridgeProtocol/`
- Move: `Sources/AwesoMuxCore/Models/TerminalSessionID.swift` → `Sources/AwesoMuxBridgeProtocol/TerminalSessionID.swift`
- Move: `Tests/AwesoMuxCoreTests/Bridge/*.swift` (6 files) → `Tests/AwesoMuxBridgeProtocolTests/`
- Modify: `Package.swift`
- Modify: `Sources/AwesoMuxBridgeHelperSupport/*.swift` (import swap, 6 files)
- Modify: ~20 `Sources/AwesoMuxCore/` files, ~28 `Sources/awesoMux/` files, and test files — add `import AwesoMuxBridgeProtocol` (compiler-driven)

**Interfaces:**
- Produces: module `AwesoMuxBridgeProtocol` exporting `BridgeEnvelope`, `BridgeMessage`, `PermissionRequest`, `PermissionDecision`, `PermissionResolved`, `BridgeStateFile`, `BridgeFrameReader`, `BridgeHandshake`, `BridgeEpochPolicy`, `BridgePendingRequestMap`, `BridgeTunables`, `TerminalSessionID` — unchanged public API, new home.
- Consumes: nothing new.

- [ ] **Step 1: Split `TerminalBackendMetadata` out of `TerminalSessionID.swift`**

`TerminalSessionID.swift` currently holds two types. `TerminalBackendMetadata` is Core-domain (session snapshots) and must NOT move. Create `Sources/AwesoMuxCore/Models/TerminalBackendMetadata.swift` containing the `TerminalBackendMetadata` struct and its doc comment (lines 64–99 of the current file, plus `import Foundation`), and delete it from `TerminalSessionID.swift`.

- [ ] **Step 2: Move the files**

```bash
mkdir -p Sources/AwesoMuxBridgeProtocol Tests/AwesoMuxBridgeProtocolTests
git mv Sources/AwesoMuxCore/Services/Bridge/BridgeEnvelope.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgeEpochPolicy.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgeFrameReader.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgeHandshake.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgePendingRequestMap.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgeStateFile.swift \
       Sources/AwesoMuxCore/Services/Bridge/BridgeTunables.swift \
       Sources/AwesoMuxBridgeProtocol/
git mv Sources/AwesoMuxCore/Models/TerminalSessionID.swift Sources/AwesoMuxBridgeProtocol/
git mv Tests/AwesoMuxCoreTests/Bridge/BridgeStateFileTests.swift \
       Tests/AwesoMuxCoreTests/Bridge/BridgeHandshakeTests.swift \
       Tests/AwesoMuxCoreTests/Bridge/BridgeFrameReaderTests.swift \
       Tests/AwesoMuxCoreTests/Bridge/BridgeEpochPolicyTests.swift \
       Tests/AwesoMuxCoreTests/Bridge/BridgePendingRequestMapTests.swift \
       Tests/AwesoMuxCoreTests/Bridge/BridgeEnvelopeTests.swift \
       Tests/AwesoMuxBridgeProtocolTests/
rmdir Sources/AwesoMuxCore/Services/Bridge Tests/AwesoMuxCoreTests/Bridge
```

The moved test files import only `Foundation` + `Testing`; they need `import AwesoMuxBridgeProtocol` added (they currently rely on `@testable import AwesoMuxCore` or plain `import AwesoMuxCore` — check each file's import line and replace the AwesoMuxCore import with `AwesoMuxBridgeProtocol`, keeping `@testable` if present).

- [ ] **Step 3: Update `Package.swift` (macOS graph)**

Add the target and test target; rewire dependencies:

```swift
.target(
    name: "AwesoMuxBridgeProtocol",
    dependencies: ["UnicodeHygiene"]
),
```

- `AwesoMuxCore` dependencies: add `"AwesoMuxBridgeProtocol"`.
- `AwesoMuxBridgeHelperSupport` dependencies: `["AwesoMuxBridgeProtocol"]` (drop `AwesoMuxCore`).
- `awesoMuxBridgeHelper` dependencies: `["AwesoMuxBridgeProtocol", "AwesoMuxBridgeHelperSupport"]` (drop `AwesoMuxCore`).
- `AwesoMuxBridgeHelperSupportTests` dependencies: `["AwesoMuxBridgeHelperSupport", "AwesoMuxBridgeProtocol", "AwesoMuxTestSupport"]` (drop `AwesoMuxCore`).
- Add:

```swift
.testTarget(
    name: "AwesoMuxBridgeProtocolTests",
    dependencies: ["AwesoMuxBridgeProtocol"]
),
```

- [ ] **Step 4: Swap imports in the helper support module**

In all 6 files of `Sources/AwesoMuxBridgeHelperSupport/` that have `import AwesoMuxCore`, replace with `import AwesoMuxBridgeProtocol`. (`BoundedUTF8FileReader.swift` imports only Foundation — untouched.)

- [ ] **Step 5: Compiler-driven import additions**

```bash
swift build 2>&1 | head -50
```

Every "cannot find type" error in `AwesoMuxCore` / `awesoMux` / test targets gets `import AwesoMuxBridgeProtocol` added after the existing imports of that file. Known consumers (from grep; expect roughly this set plus test files): in `Sources/AwesoMuxCore/`: `Stores/{RecentlyClosedWorkspaceReducer,SessionStore+Facade,SessionRestoreReducer}.swift`, `Models/{WorkspaceLayoutIntent,LiveDaemon,TerminalPane+Codable,PaneRestorationRequirement,DaemonRow,TerminalPane}.swift`, `Services/{DaemonStateResolver,DaemonGCPlan,SessionManagerSnapshotDiffer,DaemonReapGuard}.swift`; in `Sources/awesoMux/`: the `Services/Bridge*` files, `AmxBackend.swift`, `RemoteHandoff.swift`, `GhosttyRuntime.swift`, `DiagnosticsModel.swift` and siblings, `App/AwesoMuxApp.swift`, `Views/GhosttySurface/*`, `Views/SessionManagerPanel.swift`; plus `Tests/AwesoMuxTestSupport/TestData.swift` and the test files listed by `grep -rl "TerminalSessionID\|BridgeEnvelope\|BridgeStateFile" Tests/`. Repeat build-fix until clean. Do NOT use `@_exported import` (spec decision: dependencies stay visible).

- [ ] **Step 6: Run the full suite**

Run: `./script/swift-test.sh`
Expected: green (modulo any pre-existing flake documented on `main`; a flake must fail identically on the base commit to be dismissed).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(bridge): extract AwesoMuxBridgeProtocol target"
```

---

### Task 2: Platform seams in `AwesoMuxBridgeHelperSupport` (+ its tests)

**Files:**
- Modify: `Sources/AwesoMuxBridgeHelperSupport/HandoffReceiver.swift`
- Modify: `Sources/AwesoMuxBridgeHelperSupport/HelperConnection.swift`
- Modify: `Sources/AwesoMuxBridgeHelperSupport/BridgeStateFileCustody.swift`
- Modify: the 3 files in `Tests/AwesoMuxBridgeHelperSupportTests/` that `import Darwin` (`grep -l "import Darwin" Tests/AwesoMuxBridgeHelperSupportTests/`)
- Test: `Tests/AwesoMuxBridgeHelperSupportTests/HandoffReceiverTests.swift` (collision coverage)

**Interfaces:**
- Consumes: `AwesoMuxBridgeProtocol` module from Task 1.
- Produces: the same public API, now compiling under Darwin, Glibc (Linux toolchain), and Musl (Static Linux SDK). No signature changes.

- [ ] **Step 1: Ensure a deterministic publish-collision test exists (both platforms will run it)**

Check `HandoffReceiverTests.swift` for a test that publishes twice with a fixed `makeUUID` (same final name) and asserts the second call throws `.publishFailed` and leaves no temporary file. If absent, add:

```swift
@Test func secondPublishWithSameNameFailsCleanly() throws {
    let home = try TemporaryDirectory()
    let fixed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let payload = Array("hello".utf8)

    func receiveOnce() throws -> HandoffReceiver.Receipt {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(payload))
        pipe.fileHandleForWriting.closeFile()
        return try HandoffReceiver.receive(
            session: "smoke-collision",
            advisoryName: "note.md",
            expectedBytes: payload.count,
            inputDescriptor: pipe.fileHandleForReading.fileDescriptor,
            homeDirectory: home.url,
            makeUUID: { fixed }
        )
    }

    _ = try receiveOnce()
    #expect(throws: HandoffReceiver.ReceiveError.publishFailed) {
        _ = try receiveOnce()
    }
    let sessionDir = home.url
        .appendingPathComponent(".awesomux/handoffs/smoke-collision")
    let leftovers = try FileManager.default
        .contentsOfDirectory(atPath: sessionDir.path)
        .filter { $0.hasPrefix(".handoff-") }
    #expect(leftovers.isEmpty)
}
```

Adapt fixture setup (home dir with `0700` mode) to whatever pattern the existing tests in that file use — they already create custody-valid homes; mirror them exactly. Run: `swift test --filter HandoffReceiverTests` — must pass on macOS before any seam work.

- [ ] **Step 2: Add the platform import block to all three source files**

Replace `import Darwin` with:

```swift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
```

- [ ] **Step 3: Seam the atomic publish in `HandoffReceiver.receive`**

Replace the `renameatx_np` block (current lines 95–102) with:

```swift
#if canImport(Darwin)
let published = temporaryName.withCString { temporary in
    finalName.withCString { final in
        renameatx_np(sessionFD, temporary, sessionFD, final, UInt32(RENAME_EXCL))
    }
}
guard published == 0 else { throw ReceiveError.publishFailed }
shouldRemoveTemporary = false
#else
// linkat(2) publishes without overwrite on any POSIX target: link fails
// with EEXIST when the final name exists (same guarantee as Darwin's
// RENAME_EXCL) and the deferred unlinkat then drops the temporary name.
// Requires hard-link support in $HOME's filesystem — every ordinary Linux
// setup; renameat2(RENAME_NOREPLACE) is the upgrade path if a real
// hardlink-less host (exotic NFS/FUSE home) ever surfaces.
let published = temporaryName.withCString { temporary in
    finalName.withCString { final in
        linkat(sessionFD, temporary, sessionFD, final, 0)
    }
}
guard published == 0 else { throw ReceiveError.publishFailed }
// shouldRemoveTemporary stays true: after a successful link the temporary
// hard link is surplus and the defer removes exactly it, never the final.
#endif
_ = fsync(sessionFD)
```

- [ ] **Step 4: Seam the signal handling in `HandoffSignalCleanup`**

`sig_t` and `Darwin.signal` are Darwin-only names. Change the stored type and both call sites:

```swift
#if canImport(Darwin)
private typealias SignalDisposition = sig_t
#else
private typealias SignalDisposition = @convention(c) (Int32) -> Void
#endif
```

with `previousHandlers: [(Int32, SignalDisposition?)]`, and `Darwin.signal(...)` → bare `signal(...)` (resolves per-platform via the import block). If the Glibc/Musl overlay's `signal` return type mismatches the typealias, match the typealias to the overlay's return type (`__sighandler_t` on Glibc) inside the `#else` branch — the stored value is only ever passed straight back to `signal`, so the exact spelling is contained here.

- [ ] **Step 5: Seam `HelperConnection`**

- Both `SO_NOSIGPIPE` `setsockopt` blocks (init and `connect(state:session:)`) wrap in `#if canImport(Darwin) ... #endif` — the option doesn't exist on Linux.
- The write loop switches to `send(2)` with `MSG_NOSIGNAL` on Linux (per-call equivalent of `SO_NOSIGPIPE`):

```swift
#if canImport(Darwin)
let count = Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
#else
let count = send(fd, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset, Int32(MSG_NOSIGNAL))
#endif
```

- The module-qualified `Darwin.connect(fd, socketAddress, length)` inside `private static func connect(fd:path:)` MUST stay module-qualified (the class's own `connect` overloads shadow the C function), so it becomes a three-way `#if` using `Darwin.connect` / `Glibc.connect` / `Musl.connect`.
- Other `Darwin.`-qualified calls (`close`, `read`, `poll`) have no shadowing member — drop the qualifier and let the platform import resolve them.
- `sockaddr_un`, `pollfd`, `clock_gettime(CLOCK_MONOTONIC)`, `fcntl(F_SETFD, FD_CLOEXEC)` are portable as-is.

- [ ] **Step 6: Seam the test files**

In each of the 3 helper-test files importing Darwin, apply the same import block. `socketpair`, `pipe`, `fcntl` are portable. Any `SO_NOSIGPIPE` use in tests wraps in `#if canImport(Darwin)`.

- [ ] **Step 7: Integer-width fixups**

macOS `mode_t` is `UInt16`, Linux `UInt32`; some constants differ in signedness between overlays. Where the compiler complains on Linux (visible in Task 3's docker run, or CI), normalize with explicit `mode_t(...)` casts, e.g. `(status.st_mode & ~mode_t(S_IFMT)) == mode_t(S_IRUSR) | mode_t(S_IWUSR)` — never by changing the compared values. On macOS these casts are no-ops; apply them now where straightforward so the Linux build starts closer to green.

- [ ] **Step 8: Verify macOS unchanged, format, commit**

```bash
swift test --filter AwesoMuxBridgeHelperSupportTests
./script/swift-test.sh
./script/format.sh Sources/AwesoMuxBridgeHelperSupport/HandoffReceiver.swift Sources/AwesoMuxBridgeHelperSupport/HelperConnection.swift Sources/AwesoMuxBridgeHelperSupport/BridgeStateFileCustody.swift
git add -A
git commit -m "feat(bridge-helper): add linux platform seams to helper support"
```

Inspect the format diff before committing (repo rule).

---

### Task 3: `#if os(Linux)` portable manifest branch

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Produces: on Linux hosts, a manifest declaring ONLY: `UnicodeHygiene`, `AwesoMuxBridgeProtocol`, `AwesoMuxBridgeHelperSupport`, `awesoMuxBridgeHelper` (product + target), a sources-whitelisted `AwesoMuxTestSupport`, and test targets `UnicodeHygieneTests`, `AwesoMuxBridgeProtocolTests`, `AwesoMuxBridgeHelperSupportTests`. On macOS: today's full graph, unchanged.
- Consumes: Tasks 1–2 (portable targets must actually compile).

- [ ] **Step 1: Restructure `Package.swift`**

Wrap the whole `let package = Package(...)` in a platform conditional. The manifest executes on the build HOST — so `#if os(Linux)` selects the subset for native Linux builds (`swift test` in CI) while cross-compiling *from* macOS with `--swift-sdk` still evaluates the full branch (harmless: only the helper product's targets get built).

```swift
// swift-tools-version: 6.3

import PackageDescription

#if os(Linux)
// Portable subset — only the bridge helper's dependency graph builds on
// Linux; the app graph needs AppKit/GhosttyKit. Keep target definitions in
// sync with the macOS branch below when touching shared targets.
let package = Package(
    name: "awesoMux",
    products: [
        .executable(name: "awesoMuxBridgeHelper", targets: ["awesoMuxBridgeHelper"])
    ],
    targets: [
        .target(name: "UnicodeHygiene"),
        .target(
            name: "AwesoMuxBridgeProtocol",
            dependencies: ["UnicodeHygiene"]
        ),
        .target(
            name: "AwesoMuxBridgeHelperSupport",
            dependencies: ["AwesoMuxBridgeProtocol"]
        ),
        .executableTarget(
            name: "awesoMuxBridgeHelper",
            dependencies: ["AwesoMuxBridgeProtocol", "AwesoMuxBridgeHelperSupport"],
            path: "Sources/awesoMuxBridgeHelper"
        ),
        .target(
            name: "AwesoMuxTestSupport",
            path: "Tests/AwesoMuxTestSupport",
            sources: [
                "AsyncGate.swift",
                "EventRecorder.swift",
                "TemporaryDirectory.swift",
                "TestClock.swift",
                "TestScheduler.swift",
                "Wait.swift",
            ]
        ),
        .testTarget(
            name: "UnicodeHygieneTests",
            dependencies: ["UnicodeHygiene"]
        ),
        .testTarget(
            name: "AwesoMuxBridgeProtocolTests",
            dependencies: ["AwesoMuxBridgeProtocol"]
        ),
        .testTarget(
            name: "AwesoMuxBridgeHelperSupportTests",
            dependencies: ["AwesoMuxBridgeHelperSupport", "AwesoMuxBridgeProtocol", "AwesoMuxTestSupport"]
        ),
    ]
)
#else
let package = Package(
    // ... the existing full manifest exactly as it stands after Task 1 ...
)
#endif
```

The Linux `AwesoMuxTestSupport` whitelist excludes exactly `TestData.swift` and `DomainTestSupport.swift` (import AwesoMuxCore) and `UnixSocketClient.swift` (Darwin sockets, used only by macOS-side tests). The Linux branch omits the `dependencies:` package list entirely — swift-toml and swift-markdown are not in the subset's graph, and omitting them skips their fetch.

- [ ] **Step 2: Verify macOS graph is untouched**

Run: `swift build && swift test --filter AwesoMuxBridgeProtocolTests`
Expected: builds and passes exactly as before.

- [ ] **Step 3: Verify the Linux subset (docker if available)**

```bash
command -v docker >/dev/null && docker run --rm -v "$PWD:/src" -w /src swift:6.3.3 \
  bash -c 'swift test 2>&1 | tail -20'
```

Expected: all three test targets pass on Linux. This is the first time the seams from Task 2 compile against Glibc — fix any integer-width/overlay-signature errors HERE (they'll be `mode_t`/`sighandler_t`-shaped; apply the Step 7 / Step 4 patterns from Task 2). If docker is unavailable locally, push the branch and let the Task 5 workflow be the verifier — but do not proceed to Task 4 until a Linux `swift test` run is green somewhere.

Root caveat: docker/CI containers run `swift test` as root, and root bypasses permission checks (DAC). Inspect the helper test suites for any test asserting an *access-denied* outcome (a failed `open`/`mkdir` due to modes, as opposed to the custody code's explicit mode-bit comparisons, which root does not affect). If any exist, run the container tests as a non-root user (`useradd -m runner` + `su runner -c 'swift test'`); if none, note that in the workflow comment and run as root.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "build(package): add linux portable manifest branch"
```

(If Step 3 forced seam fixes, commit those with the Task 2 message pattern first.)

---

### Task 4: `script/build_linux_helper.sh` (cross-compile both arches)

**Files:**
- Create: `script/build_linux_helper.sh` (mode 0755)

**Interfaces:**
- Produces: `dist/linux-helper/awesomux-bridge-helper-linux-{x86_64,aarch64}` + `.sha256` sidecars. Consumed verbatim by Tasks 5 and 6.
- Consumes: the Linux-capable package graph from Tasks 1–3.

- [ ] **Step 1: Resolve the Static Linux SDK pin**

```bash
SDK_URL="https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz"
curl -fsSL "$SDK_URL" -o /tmp/static-sdk.tar.gz
shasum -a 256 /tmp/static-sdk.tar.gz
```

Cross-check the URL against https://www.swift.org/install (the static-sdk artifact name suffix can differ per release; use the published one for 6.3.3) and cross-check the checksum against the value published there. Pin BOTH into the script in the next step. This is the same reviewed-pin model as `.github/swift-toolchain-checksums.txt`.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# Cross-compiles the static Linux bridge helper for both supported
# architectures. Needs a swift.org toolchain matching .swift-version —
# Xcode's toolchain cannot use the Static Linux SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_VERSION="$(cat .swift-version)"
# Static Linux SDK pin — MUST move in lockstep with .swift-version
# (docs/toolchain.md). Checksum is the swift.org-published value, reviewed
# on bump like .github/swift-toolchain-checksums.txt rows.
SDK_URL="<pinned URL from Step 1>"
SDK_CHECKSUM="<pinned checksum from Step 1>"
SDK_ID_PREFIX="swift-${SWIFT_VERSION}-RELEASE_static-linux"

if ! swift --version 2>/dev/null | grep -q "Swift version ${SWIFT_VERSION}"; then
  echo "error: active toolchain is not Swift ${SWIFT_VERSION}." >&2
  echo "       Install via swiftly (https://www.swift.org/install) and retry;" >&2
  echo "       the Xcode toolchain cannot consume the Static Linux SDK." >&2
  exit 1
fi

if ! swift sdk list 2>/dev/null | grep -q "${SDK_ID_PREFIX}"; then
  swift sdk install "${SDK_URL}" --checksum "${SDK_CHECKSUM}"
fi

checksum() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

mkdir -p dist/linux-helper
for arch in x86_64 aarch64; do
  swift build -c release --product awesoMuxBridgeHelper --swift-sdk "${arch}-swift-linux-musl"
  out="dist/linux-helper/awesomux-bridge-helper-linux-${arch}"
  install -m 0755 ".build/${arch}-swift-linux-musl/release/awesoMuxBridgeHelper" "${out}"
  (cd dist/linux-helper && checksum "$(basename "${out}")" > "$(basename "${out}").sha256")
done

echo "Built:"
ls -l dist/linux-helper/
```

Replace the two `<pinned …>` markers with the Step 1 values before committing — the committed script must contain the literal URL and checksum. If the exact `--swift-sdk` triple name differs in `swift sdk list` output after install (it prints the installed SDK ids), use the listed id.

- [ ] **Step 3: Verify**

On a machine with the swift.org 6.3.3 toolchain: run `./script/build_linux_helper.sh`, then:

```bash
file dist/linux-helper/awesomux-bridge-helper-linux-*   # expect: ELF 64-bit, statically linked
arch="$(uname -m | sed 's/arm64/aarch64/')"
docker run --rm -v "$PWD/dist/linux-helper:/h" ubuntu:24.04 "/h/awesomux-bridge-helper-linux-${arch}" --version
```

Expected `--version` output, exactly:

```
awesomux-bridge-v1
awesomux-handoff-v1
```

If no swift.org toolchain is installed locally, verification happens in the Task 5 workflow's build job — the script is still committed now, and the smoke run in CI is the gate.

- [ ] **Step 4: Commit**

```bash
git add script/build_linux_helper.sh
git commit -m "build(bridge-helper): add static linux cross-compile script"
```

---

### Task 5: Linux CI workflow + sshd smoke script

**Files:**
- Create: `.github/workflows/linux-helper.yml`
- Create: `script/ci/linux_handoff_smoke.sh` (mode 0755)

**Interfaces:**
- Consumes: `script/build_linux_helper.sh` (Task 4), the Linux manifest branch (Task 3).
- Produces: required CI signal for helper-graph changes; smoke script reused manually against real hosts.

- [ ] **Step 1: Write the smoke script**

`script/ci/linux_handoff_smoke.sh` — takes the helper binary path as `$1`, drives a dockerized sshd end to end:

```bash
#!/usr/bin/env bash
# End-to-end SSH smoke for the Linux bridge helper (#87 acceptance):
# real sshd, real ssh, manual-install layout, receipt + custody + cleanup
# assertions. Runs in CI (ubuntu runner) or locally anywhere docker works.
set -euo pipefail

HELPER="${1:?usage: linux_handoff_smoke.sh <helper-binary>}"
CONTAINER="awesomux-handoff-smoke"
PORT=2222
KEYDIR="$(mktemp -d)"
SSH_OPTS=(-p "$PORT" -i "$KEYDIR/id" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH=(ssh "${SSH_OPTS[@]}" handoff@127.0.0.1)

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$KEYDIR"; }
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# --- sshd container -------------------------------------------------------
docker run -d --name "$CONTAINER" -p "127.0.0.1:${PORT}:22" ubuntu:24.04 sleep infinity >/dev/null
docker exec "$CONTAINER" bash -c \
  'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null && mkdir -p /run/sshd'
ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/id"
docker exec "$CONTAINER" useradd -m -s /bin/bash handoff
docker exec "$CONTAINER" install -d -m 700 -o handoff -g handoff /home/handoff/.ssh
docker cp "$KEYDIR/id.pub" "$CONTAINER:/home/handoff/.ssh/authorized_keys"
docker exec "$CONTAINER" bash -c \
  'chown handoff:handoff /home/handoff/.ssh/authorized_keys && chmod 600 /home/handoff/.ssh/authorized_keys'
docker exec -d "$CONTAINER" /usr/sbin/sshd -D
for _ in $(seq 1 30); do
  "${SSH[@]}" true 2>/dev/null && break
  sleep 1
done
"${SSH[@]}" true || fail "sshd never came up"

# --- manual install, per docs/remote-linux-helper.md ----------------------
# Piped over ssh rather than scp: scp's -p means preserve-times (its port
# flag is -P), so reusing SSH_OPTS with scp silently targets port 22.
"${SSH[@]}" 'install -d -m 700 ~/.awesomux && install -d -m 755 ~/.awesomux/bin'
"${SSH[@]}" 'cat > ~/.awesomux/bin/awesomux-bridge-helper' < "$HELPER"
"${SSH[@]}" 'chmod 755 ~/.awesomux/bin/awesomux-bridge-helper'

# --- acceptance: --version advertises both protocols ----------------------
VERSION_OUT="$("${SSH[@]}" '~/.awesomux/bin/awesomux-bridge-helper --version')"
[[ "$VERSION_OUT" == $'awesomux-bridge-v1\nawesomux-handoff-v1' ]] \
  || fail "unexpected --version output: $VERSION_OUT"

# --- acceptance: successful handoff ---------------------------------------
SID="0f0e6c56-9d1f-4c7e-9b1a-3d6f2a54e7c1"
PAYLOAD="hello linux handoff"
RECEIPT="$(printf '%s' "$PAYLOAD" | "${SSH[@]}" \
  "~/.awesomux/bin/awesomux-bridge-helper receive-handoff --session $SID --name note.md --expected-bytes ${#PAYLOAD}")"
REMOTE_PATH="$(printf '%s' "$RECEIPT" | jq -re .path)"
BYTES="$(printf '%s' "$RECEIPT" | jq -re .bytes)"
[[ "$BYTES" == "${#PAYLOAD}" ]] || fail "receipt bytes $BYTES != ${#PAYLOAD}"
[[ "$REMOTE_PATH" == "/home/handoff/.awesomux/handoffs/$SID/"*.md ]] \
  || fail "receipt path off-contract: $REMOTE_PATH"
[[ "$("${SSH[@]}" "cat '$REMOTE_PATH'")" == "$PAYLOAD" ]] || fail "content mismatch"
[[ "$("${SSH[@]}" "stat -c '%a' ~/.awesomux/handoffs")" == "700" ]] || fail "handoffs dir mode"
[[ "$("${SSH[@]}" "stat -c '%a' ~/.awesomux/handoffs/$SID")" == "700" ]] || fail "session dir mode"
[[ "$("${SSH[@]}" "stat -c '%a' '$REMOTE_PATH'")" == "600" ]] || fail "file mode"

# --- acceptance: early EOF fails without leftovers ------------------------
SID2="1a2b3c4d-0000-4000-8000-000000000002"
if printf 'abc' | "${SSH[@]}" \
  "~/.awesomux/bin/awesomux-bridge-helper receive-handoff --session $SID2 --name x.md --expected-bytes 9999"; then
  fail "early-EOF handoff unexpectedly succeeded"
fi
LEFTOVERS="$("${SSH[@]}" "ls -A ~/.awesomux/handoffs/$SID2 2>/dev/null | wc -l")"
[[ "$LEFTOVERS" == "0" ]] || fail "early EOF left $LEFTOVERS file(s) behind"

echo "SMOKE PASS"
```

`jq` is preinstalled on ubuntu runners; the script requires it.

- [ ] **Step 2: Write the workflow**

`.github/workflows/linux-helper.yml`. Copy the pinned action SHAs from `.github/workflows/cheap-guards.yml` (checkout) and `release.yml` (upload-artifact); find the repo's pinned `download-artifact` SHA via `grep -rn "download-artifact" .github/workflows/` (pin a new one at the current major if absent, matching the repo's sha-pin style):

```yaml
name: Linux helper

on:
  pull_request:
    paths: &helper-paths
      - "Sources/AwesoMuxBridgeProtocol/**"
      - "Sources/AwesoMuxBridgeHelperSupport/**"
      - "Sources/awesoMuxBridgeHelper/**"
      - "Sources/UnicodeHygiene/**"
      - "Tests/AwesoMuxBridgeProtocolTests/**"
      - "Tests/AwesoMuxBridgeHelperSupportTests/**"
      - "Tests/AwesoMuxTestSupport/**"
      - "Tests/UnicodeHygieneTests/**"
      - "Package.swift"
      - "script/build_linux_helper.sh"
      - "script/ci/linux_handoff_smoke.sh"
      - ".github/workflows/linux-helper.yml"
  push:
    branches: ["main"]
    paths: *helper-paths

permissions:
  contents: read

jobs:
  linux-tests:
    name: Linux unit tests
    runs-on: ubuntu-24.04
    container: swift:6.3.3-noble
    timeout-minutes: 30
    steps:
      - name: Checkout repository
        uses: actions/checkout@<pinned-sha> # copy pin from cheap-guards.yml
        with:
          persist-credentials: false
      - name: Run portable test targets
        run: swift test

  build:
    name: Cross-compile static helpers
    runs-on: ubuntu-24.04
    container: swift:6.3.3-noble
    timeout-minutes: 30
    steps:
      - name: Checkout repository
        uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - name: Build both architectures
        run: ./script/build_linux_helper.sh
      - name: Upload helper artifacts
        uses: actions/upload-artifact@<pinned-sha> # copy pin from release.yml
        with:
          name: linux-helper
          path: dist/linux-helper/
          if-no-files-found: error

  smoke:
    name: SSH end-to-end smoke
    needs: build
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - name: Checkout repository
        uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - name: Download helper artifacts
        uses: actions/download-artifact@<pinned-sha>
        with:
          name: linux-helper
          path: dist/linux-helper/
      - name: Run smoke against dockerized sshd
        run: |
          chmod +x dist/linux-helper/awesomux-bridge-helper-linux-x86_64
          ./script/ci/linux_handoff_smoke.sh dist/linux-helper/awesomux-bridge-helper-linux-x86_64
```

Notes for the implementer: verify the `swift:6.3.3-noble` tag exists (`docker manifest inspect swift:6.3.3-noble`); fall back to `swift:6.3.3` if not. The build job re-downloads the Static Linux SDK every run (accepted cost, a few hundred MB — add a comment saying so; actions/cache is the upgrade if it starts hurting). YAML anchors (`&helper-paths`) are not supported by GitHub Actions — inline the path list twice instead (the anchor above is plan shorthand only). The aarch64 binary is build-verified only (no arm64 runner); the x86_64 binary carries the smoke.

- [ ] **Step 3: Verify workflow hygiene**

Run: `node --test .github/scripts/test/` (repo's workflow guard tests) and `actionlint .github/workflows/linux-helper.yml` if available.
Expected: existing guard tests still pass (none should reference the new workflow; if a guard enumerates workflows, extend it per its own pattern).

- [ ] **Step 4: Commit, push, watch**

```bash
git add .github/workflows/linux-helper.yml script/ci/linux_handoff_smoke.sh
git commit -m "ci(bridge-helper): add linux unit, cross-compile, and ssh smoke jobs"
git push
gh run watch --exit-status "$(gh run list --branch issue/87-linux-bridge-helper --workflow linux-helper.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: all three jobs green. Iterate here until they are — this is where Linux-only compile errors and smoke assertions get resolved for real.

---

### Task 6: Release artifacts

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `docs/releasing.md` (mention the new artifacts)

**Interfaces:**
- Consumes: `script/build_linux_helper.sh` (Task 4).
- Produces: `awesomux-bridge-helper-linux-{x86_64,aarch64}` + `.sha256` attached to every draft release.

- [ ] **Step 1: Add the Linux build job to `release.yml`**

```yaml
  linux-helper:
    name: Cross-compile Linux helpers
    runs-on: ubuntu-24.04
    container: swift:6.3.3-noble
    timeout-minutes: 30
    steps:
      - name: Checkout repository
        uses: actions/checkout@<same pinned sha as the release job>
        with:
          persist-credentials: false
      - name: Build both architectures
        run: ./script/build_linux_helper.sh
      - name: Upload helper artifacts
        uses: actions/upload-artifact@<same pinned sha as the release job>
        with:
          name: linux-helper
          path: dist/linux-helper/
          if-no-files-found: error
```

(No submodules, no signing environment — this job must NOT get `environment: release` or any secret.)

- [ ] **Step 2: Feed the artifacts into the release job**

- Add `needs: [linux-helper]` to the existing `release` job.
- Immediately before the `gh release create` step, add:

```yaml
      - name: Download Linux helper artifacts
        if: inputs.create_draft_release || startsWith(github.ref, 'refs/tags/')
        uses: actions/download-artifact@<pinned-sha>
        with:
          name: linux-helper
          path: dist/release/
```

- Extend the `gh release create` argument list:

```
            "dist/release/awesomux-bridge-helper-linux-x86_64" \
            "dist/release/awesomux-bridge-helper-linux-x86_64.sha256" \
            "dist/release/awesomux-bridge-helper-linux-aarch64" \
            "dist/release/awesomux-bridge-helper-linux-aarch64.sha256"
```

- [ ] **Step 3: Update `docs/releasing.md`**

Add a short paragraph: releases now include static Linux bridge-helper binaries for x86_64/aarch64, built by the `linux-helper` job from `script/build_linux_helper.sh`; verification and manual-install instructions live in `docs/remote-linux-helper.md`.

- [ ] **Step 4: Verify and commit**

Run: `node --test .github/scripts/test/` and `actionlint .github/workflows/release.yml` if available. A full release dry-run is NOT required for this PR (the workflow's next `workflow_dispatch` exercises it); the review gate covers the YAML.

```bash
git add .github/workflows/release.yml docs/releasing.md
git commit -m "ci(release): attach static linux bridge helpers to releases"
```

---

### Task 7: Documentation

**Files:**
- Create: `docs/remote-linux-helper.md`
- Modify: `docs/toolchain.md` (SDK-pin bump procedure)
- Modify: `AGENTS.md` (stack table, "Remote SSH workspaces" row — add the Linux-helper pointer)

**Interfaces:**
- Consumes: everything prior; documents the shipped state only.

- [ ] **Step 1: Write `docs/remote-linux-helper.md`**

```markdown
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

`.github/workflows/linux-helper.yml` runs the portable test targets on
Linux, cross-compiles both binaries, and drives an end-to-end SSH smoke
(`script/ci/linux_handoff_smoke.sh`) against a real sshd on every change to
the helper's dependency graph.
```

- [ ] **Step 2: Update `docs/toolchain.md`**

In the version-bump procedure, add a step: "Update the Static Linux SDK pin (URL + checksum) in `script/build_linux_helper.sh` to the matching release, and the `swift:X.Y.Z-*` container tags in `.github/workflows/linux-helper.yml` and `.github/workflows/release.yml`."

- [ ] **Step 3: Update `AGENTS.md` stack table**

In the "Remote SSH workspaces" row, append: "Linux destinations use a manually installed static helper ([`docs/remote-linux-helper.md`](docs/remote-linux-helper.md))."

- [ ] **Step 4: Commit**

```bash
git add docs/remote-linux-helper.md docs/toolchain.md AGENTS.md
git commit -m "docs(remote): document the linux bridge helper"
```

---

### Task 8: Preflight, review gate, PR

- [ ] **Step 1: Full preflight**

Run: `./script/preflight.sh`
Expected: all guards pass; the swift-test step green (pre-existing flakes must be shown to fail identically on the base commit before being dismissed).

- [ ] **Step 2: Pre-merge review gate**

Run the repository's multi-reviewer review on the branch diff (per the repo's pre-merge review hook) and resolve findings.

- [ ] **Step 3: Open the PR**

- Title: `feat(remote): support linux destinations for file handoff`
- Body: Why (closes #87, one-paragraph summary of the settled design), What's Included (per-task summary), Validation (preflight, Linux CI runs, smoke), UI/UX (none — no visible app change; Linux destinations gain paste), Risk Notes (extraction is move-only; Darwin publish path unchanged; new CI surface), AI assistance level (ASK the maintainer — do not infer).
- Link issue #87.
