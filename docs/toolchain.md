# Swift toolchain

awesoMux pins its native Apple toolchain separately from the released Linux
toolchain:

- `.swift-version-macos` pins Apple Swift 6.4 for native builds.
- `.xcode-version` pins Xcode 27.0, with the macOS 27 SDK.
- `.swift-version` retains Swift 6.3.3 for Linux helpers and Linux formatting CI.
  Version managers that read this conventional file on macOS still select the
  OSS baseline; native work uses the selected Xcode toolchain instead.
- `.swift-format-version` records the toolchain-integrated `swift format`
  version for each supported host platform. Xcode 27 reports `main`; Linux
  Swift 6.3.3 reports `6.3.3`. The macOS formatter guard also checks the Xcode,
  SDK, and compiler pins, so `main` alone is never accepted as an identity.
- `.swift-format` owns formatting behavior.
- `Package.swift` retains tools version 6.3 so the released Linux compiler can
  build the helper targets. A compiler upgrade does not require new manifest APIs.

`script/check-toolchain.sh` verifies the installed versions. Cheap guards runs
inside `swift:6.3.3-noble` on `ubuntu-24.04`, matching the Linux helper and release
jobs. The container supplies Swift independently of runner image updates; the
version check still runs before formatting checks.

Local commands validate the selected toolchain and reject mismatches; they do
not change the system selection. For Xcode 27 installed as `Xcode.app`, use:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset TOOLCHAINS
./script/check-toolchain.sh
```

`TOOLCHAINS` may also explicitly name `com.apple.dt.toolchain.XcodeDefault`.
Other overrides are rejected even when their Swift version matches; native
builds require the compiler and formatter bundled with the selected Xcode.

As of September 14, 2026, [Swift.org](https://www.swift.org/install/linux/)
publishes Swift 6.4 Linux SDKs only as development snapshots, and the
[official Docker image manifest](https://github.com/docker-library/official-images/blob/master/library/swift)
still publishes `swift:6.3.3-noble`. Keep that compiler, Static Linux SDK URL,
and checksum together rather than inventing a 6.4 release tag.

Native workflows select the `.xcode-version` app alias and verify the toolchain
before building. The GitHub `xcode-27` arm64 image runs macOS 27 but remains a
[public preview](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/).
Its published image manifest can lag the local Xcode release; a compiler or
SDK mismatch fails explicitly. Updating these workflows does not establish a
hosted validation result. `NATIVE_CI_RUNNER` overrides remain available.

## Zig with SDK 27

Zig 0.16 needs the SDK 27 compatibility header already used by its Ghostty
dependency. `script/build_amx.sh` applies the same MIT-licensed header to the
top-level zmx build and tests through the supported `ZIG_LIBC` configuration.
It generates that configuration under `.build/amx` for the selected SDK,
without changing vendor sources or the SDK. An explicit `ZIG_LIBC` override
remains the responsibility of the caller.

## Everyday formatting

Format only the first-party Swift files intentionally changed, inspect the
result, and then run the changed-lines lint:

```sh
./script/check-toolchain.sh
./script/format.sh Sources/AwesoMuxCore/Example.swift Tests/AwesoMuxCoreTests/ExampleTests.swift
git diff --check
./script/format.sh --lint
```

Write mode accepts `Package.swift` and explicit `.swift` files under `Sources/`
or `Tests/`. It rejects repository-wide formatting, vendored code, generated
code, and formatter versions that do not match `.swift-format-version`.

Within those files it rewrites **only the lines changed from the base ref** —
the same range lint mode judges. A file with no tracked history is formatted
whole; a file with no changed lines is left untouched. Set `FORMAT_LINT_BASE`
to override the comparison ref for either mode.

This scoping matters because roughly a third of *sampled* files carry
whole-file formatting drift that changed-lines lint cannot see (34 of 109
checked on 2026-07-24). Formatting those files end-to-end would bury a small
edit under hundreds of unrelated lines and rewrite `git blame` for code the
change never touched.

Two consequences worth expecting. A formatted line in a drift-carrying file
will not visually match its unformatted neighbours — that mismatch is correct,
and hand-matching the neighbours will fail lint, because the formatted line is
the canonical one. And the base ref is `merge-base origin/main HEAD`, falling
back to `HEAD` when `origin/main` is absent; on a fork without that remote,
"changed" therefore means "uncommitted", so committing your work removes it
from both modes. Set `FORMAT_LINT_BASE` to widen the range.

## Updating Swift

Treat a toolchain update as a deliberate maintenance change:

1. Verify the actual compiler, formatter, Xcode, and SDK versions on the native
   host. Update `.swift-version-macos` and `.xcode-version` together.
2. Update `.swift-version` only when the corresponding stable Linux toolchain,
   Static Linux SDK, and Docker images are all published.
3. Keep `Package.swift`'s tools version compatible with every supported compiler;
   raise it only when new manifest APIs require it.
4. Update each platform entry in `.swift-format-version` to the
   `swift format --version` shipped with that platform's toolchain.
5. Run `./script/check-toolchain.sh` and `./script/test-toolchain.sh` locally.
6. Run `./script/test-format.sh` and `./script/format.sh --lint` without applying
   a repository-wide reformat.
7. When changing the Linux pin, update the Static Linux SDK (URL + checksum) in
   `script/build_linux_helper.sh` to the matching release, and the
   `swift:X.Y.Z-*` container tags in `.github/workflows/cheap-guards.yml`,
   `.github/workflows/linux-helper.yml`, and `.github/workflows/release.yml`.
   Their `-noble` suffix is an explicit Ubuntu baseline, not derived from the
   Swift version; update it deliberately across the workflows and parity test.
8. Run `./script/preflight.sh` before opening the pull request.
9. Read existing hosted results; a human launches any requested native CI.

If the new formatter reports existing debt, keep CI scoped to changed lines.
Do not combine a toolchain bump with whole-codebase formatting unless that
separate migration is explicitly planned and coordinated.
