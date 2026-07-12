import Testing
@testable import awesoMux

/// Truth table for `BridgeCwdRefreshPolicy` — both decision helpers are pure
/// so they test without AppKit, a store, or a running daemon.
@Suite("BridgeCwdRefreshPolicy")
struct BridgeCwdRefreshPolicyTests {

    // MARK: - shouldRefreshCwdFromAmx

    @Test("both bridgeEnabled and isBridgePane true → should refresh")
    func bothTrue_returnsTrue() {
        #expect(BridgeCwdRefreshPolicy.shouldRefreshCwdFromAmx(
            bridgeEnabled: true, isBridgePane: true
        ) == true)
    }

    @Test("bridgeEnabled false → should not refresh regardless of pane type")
    func bridgeEnabledFalse_returnsFalse() {
        #expect(BridgeCwdRefreshPolicy.shouldRefreshCwdFromAmx(
            bridgeEnabled: false, isBridgePane: true
        ) == false)
    }

    @Test("isBridgePane false → should not refresh even when bridge feature is on")
    func isBridgePaneFalse_returnsFalse() {
        #expect(BridgeCwdRefreshPolicy.shouldRefreshCwdFromAmx(
            bridgeEnabled: true, isBridgePane: false
        ) == false)
    }

    @Test("both false → should not refresh")
    func bothFalse_returnsFalse() {
        #expect(BridgeCwdRefreshPolicy.shouldRefreshCwdFromAmx(
            bridgeEnabled: false, isBridgePane: false
        ) == false)
    }

    // MARK: - cwdUpdate(current:queried:)

    @Test("non-empty queried that differs from current → returns queried")
    func queriedNonEmpty_differs_returnsQueried() {
        let result = BridgeCwdRefreshPolicy.cwdUpdate(
            current: "/Users/alice/Projects/foo",
            queried: "/Users/alice/Projects/bar"
        )
        #expect(result == "/Users/alice/Projects/bar")
    }

    @Test("empty queried string → returns nil (never blanks the bar)")
    func queriedEmpty_returnsNil() {
        let result = BridgeCwdRefreshPolicy.cwdUpdate(
            current: "/Users/alice/Projects/foo",
            queried: ""
        )
        #expect(result == nil)
    }

    @Test("nil queried → returns nil")
    func queriedNil_returnsNil() {
        let result = BridgeCwdRefreshPolicy.cwdUpdate(
            current: "/Users/alice/Projects/foo",
            queried: nil
        )
        #expect(result == nil)
    }

    @Test("queried same as current → returns nil (no-op write)")
    func queriedSameAsCurrent_returnsNil() {
        let result = BridgeCwdRefreshPolicy.cwdUpdate(
            current: "/Users/alice/Projects/foo",
            queried: "/Users/alice/Projects/foo"
        )
        #expect(result == nil)
    }
}
