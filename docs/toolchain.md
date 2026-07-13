# Swift toolchain

awesoMux uses one pinned Swift toolchain for package manifests, local formatting,
and formatting CI:

- `.swift-version` pins the Swift release.
- `.swift-format-version` records the toolchain-integrated `swift format`
  version for each supported host platform. Swift 6.3.3 reports different
  formatter version strings in Xcode and the Linux toolchain.
- `.swift-format` owns formatting behavior.
- `Package.swift` declares the matching Swift tools version.

`script/check-toolchain.sh` verifies the installed versions. CI runs that check
on `ubuntu-24.04` before any formatter checks, so a hosted-runner image update
fails clearly instead of silently producing a different format.

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

## Updating Swift

Treat a toolchain update as a deliberate maintenance change:

1. Choose the newest stable Swift patch release available in Xcode and on the
   GitHub Actions Ubuntu image.
2. Update `.swift-version` to the full Swift patch release, such as `6.3.3`.
3. Update the first-line `swift-tools-version` declaration in `Package.swift`
   to the matching minor release, such as `6.3`.
4. Update each platform entry in `.swift-format-version` to the
   `swift format --version` shipped with that platform's toolchain.
5. Run `./script/check-toolchain.sh` locally.
6. Run `./script/test-format.sh` and `./script/format.sh --lint` without applying
   a repository-wide reformat.
7. Run `./script/preflight.sh` before opening the pull request.
8. Confirm the Cheap guards workflow passes with the same pinned versions.

If the new formatter reports existing debt, keep CI scoped to changed lines.
Do not combine a toolchain bump with whole-codebase formatting unless that
separate migration is explicitly planned and coordinated.
