// Pure, testable decision helpers for bridge-pane cwd refresh.
//
// A bridge pane runs a daemon shell that does NOT emit OSC 7, so its cwd goes
// stale as soon as the user changes directories. `AmxBackend.queryCwd` is the
// out-of-band oracle; this policy owns WHEN to call it and WHAT to write back.
//
// Everything here is side-effect free — the view layer (TerminalPathBarView) is
// the enactor. Tests live in BridgeCwdRefreshPolicyTests.
enum BridgeCwdRefreshPolicy {
    /// Returns true only when BOTH the command-bridge feature flag is on AND this
    /// specific pane has an established bridge session. Guards the
    /// `AmxBackend.queryCwd` call so non-bridge panes and bridge-disabled configs
    /// are never queried.
    static func shouldRefreshCwdFromAmx(bridgeEnabled: Bool, isBridgePane: Bool) -> Bool {
        bridgeEnabled && isBridgePane
    }

    /// Returns the new cwd to write when `queried` is non-empty and differs from
    /// `current`, nil otherwise. Callers must never blank the bar — returning nil
    /// instead of "" on an empty query keeps the last known path visible.
    static func cwdUpdate(current: String, queried: String?) -> String? {
        guard let queried, !queried.isEmpty, queried != current else { return nil }
        return queried
    }
}
