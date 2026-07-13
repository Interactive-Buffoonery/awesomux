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
