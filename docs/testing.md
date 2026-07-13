# Test suite baseline

This document records the starting point for the deterministic hosted Swift CI
rebuild. The baseline was captured from an untouched `origin/main` before any
test organization or behavior changed.

## Baseline run

| Field | Value |
| --- | --- |
| Captured | 2026-07-13 16:42 UTC |
| Commit | `f22c8281c85a56a35b7e2fac8adb598b95a112a5` |
| Environment | MacBook Pro, Apple M5 Max, 64 GB |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.4 (17E192) |
| Swift | 6.3 |
| Command | `./script/swift-test.sh --xunit-output .build/test-results/baseline.xml` |
| Result | 3,483 tests in 380 suites passed |
| Failures | 0 |
| Skipped | 0 |
| Wall time | 61.75 seconds |
| Swift Testing reported time | 3.476 seconds |

The wall time includes build and test-process startup. Swift Testing runs
independent tests concurrently, so individual test durations overlap and do
not add up to the wall time. The raw log and xUnit report remain uncommitted
under `.build/test-results/`.

### Slowest test cases

| Test | Duration |
| --- | ---: |
| `ClaudeCodexPluginTemplateTests.bundledClaudeMarketplaceValidates()` | 3.466 s |
| `RuntimeProfileScriptTests.reaperSelectsLegacyDevelopmentProfile()` | 2.935 s |
| `RuntimeProfileScriptTests.reaperUsesInjectedPaneProfile()` | 2.852 s |
| `RuntimeProfileScriptTests.reaperSelectsWorktreeProfile()` | 2.761 s |
| `RuntimeProfileScriptTests.reaperDefaultsAndValidation()` | 2.350 s |
| `RemoteConnectivityObserverTests.connectivityChurnDebouncesToOneStaleMark()` | 2.259 s |
| `RemoteConnectivityObserverTests.restartTreatsNextPathMonitorUpdateAsNewBaseline()` | 2.259 s |
| `RemoteConnectivityObserverTests.wakeNotificationIsObservedOnlyWhileRunning()` | 2.259 s |
| `RemoteConnectivityObserverTests.initialPathMonitorUpdateIsTreatedAsBaseline()` | 2.259 s |
| `RemoteConnectivityObserverTests.deinitStopsObserverAndCancelsPendingDebounce()` | 2.259 s |

## Initial test groups

The initial groups follow existing SwiftPM test-target boundaries. This records
the current suite without moving or rewriting tests. In this first map,
"system" means tests coupled to the app executable target; it does not mean
that every test in that target is end-to-end.

| Group | Test target | Swift files | Tests |
| --- | --- | ---: | ---: |
| Unit | `AwesoMuxCoreTests` | 130 | 1,427 |
| Unit | `AwesoMuxConfigTests` | 14 | 212 |
| Unit | `DesignSystemTests` | 10 | 91 |
| Unit | `UnicodeHygieneTests` | 1 | 25 |
| Unit | `SecureFileIOTests` | 1 | 7 |
| Adapter | `AwesoMuxAgentHookSupportTests` | 6 | 82 |
| Adapter | `AwesoMuxBridgeHelperSupportTests` | 4 | 31 |
| System | `awesoMuxTests` | 180 | 1,608 |
| **Total** | **8 targets** | **346** | **3,483** |

| Group | Swift files | Tests |
| --- | ---: | ---: |
| Unit | 156 | 1,762 |
| Adapter | 10 | 113 |
| System | 180 | 1,608 |
| **Total** | **346** | **3,483** |

## Running test groups

Use the Ghostty-aware group wrapper for focused or full Swift test runs:

```sh
./script/test.sh unit
./script/test.sh adapter
./script/test.sh system
./script/test.sh all
```

Arguments after the group are passed to `swift test`. For example,
`./script/test.sh unit --xunit-output result.xml` records the unit result.
`./script/preflight.sh` remains the complete local check, including non-Swift
guards and app launch verification.

### Initial group check

| Command | Selected tests | Result |
| --- | ---: | --- |
| `./script/test.sh unit` | 1,762 | Passed |
| `./script/test.sh adapter` | 113 | Passed |
| `./script/test.sh system` | 1,608 | Failed with 3 issues |
| `./script/test.sh all` | 3,483 | Passed |

The isolated system run exposes an existing ordering dependency in
`AppearanceUIFontResolutionTests`: two tests expect the bundled Geist font to
have been registered by another test target. The full suite passes because
that registration happens elsewhere during the run. This baseline records the
isolation failure without broadening the system group or hiding it.

## Test organization rules

These rules apply to new tests and tests changed as part of feature work.
Existing exceptions remain part of the baseline until a focused follow-up
changes them.

### Naming

- Name files `<Subject>Tests.swift` after the behavior or production type under
  test.
- Name suites after the subject they cover.
- Name tests for the condition and expected outcome.
- Do not use issue or pull request numbers as the main test name.

### Folders

- Put tests under `Tests/<ProductionTarget>Tests`.
- Use a feature subfolder when several related test files are easier to find
  together. Keep a single test file at the target root.
- Do not create a separate folder hierarchy that duplicates production folders
  without making the tests easier to find.

### Ownership

- Put a test in the lowest production target that can exercise the behavior.
- Unit tests use controlled inputs and do not require the running app or a real
  external boundary.
- Adapter tests exercise one boundary, such as a helper protocol or process
  interface, while keeping the behavior on the other side controlled.
- System tests exercise app or operating-system integration. Tests that import
  the `awesoMux` executable remain in the system group until a later change
  extracts the behavior into a lower target.

### Serialization

- Tests run concurrently by default.
- Use `.serialized` only when tests share process-wide or operating-system state
  that cannot be isolated, such as AppKit lifecycle state, environment changes,
  or one fixed socket endpoint.
- A serialized suite must restore the shared state it changes.
- Do not serialize a suite to hide a race or timing failure. Replace the shared
  state or timing dependency instead.
- Serialize the smallest affected suite, not the full test group.
