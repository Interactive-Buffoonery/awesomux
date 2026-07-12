import Foundation

/// Runtime-only reconnect affordance for a remote pane whose bridge died
/// (INT-697). `agentExecutionState == .error` can't gate the reconnect
/// overlay by itself — `VisibleTextAgentStateReducer` also sets `.error` from
/// ordinary agent output on a live pane — so this is a dedicated field.
public enum RemoteReconnectState: Equatable, Hashable, Sendable {
    /// Overlay shown with an enabled reconnect button.
    case disconnected(Context)
    /// Overlay shown with the button disabled ("Reconnecting…") while a
    /// respawn is in flight.
    case reconnecting(Context)

    /// Payload carried through both states. The `target` is snapshotted at
    /// latch time (so it survives the pane moving groups) and refreshed to the
    /// live target at dial time; the two flags are latch/dial provenance the
    /// confirm/announce paths read, deliberately kept OUT of equality (below).
    public struct Context: Sendable {
        /// Host for overlay display + a11y. Captured at latch (disconnect);
        /// `SessionStore.markPaneRemoteReconnecting` refreshes it to the live
        /// group target at dial time so the recovery announcement names the
        /// host actually dialed (INT-697 fix #9).
        public var target: RemoteTarget
        /// True when the error latch pushed a NON-error pane into `.error`.
        /// Only then does `confirmPaneRemoteReconnected`/heal reset `.error` on
        /// recovery — an `.error` set from agent OUTPUT before the bridge died
        /// must survive the reconnect (INT-697 fix #2).
        public var displacedNonErrorState: Bool
        /// True only when the in-flight reconnect dialed a LOCAL restart (the
        /// session moved to a local group, so there is no host), so the
        /// recovery announcement is host-agnostic (INT-697 fix #9).
        public var dialedLocalRestart: Bool

        public init(
            target: RemoteTarget,
            displacedNonErrorState: Bool = false,
            dialedLocalRestart: Bool = false
        ) {
            self.target = target
            self.displacedNonErrorState = displacedNonErrorState
            self.dialedLocalRestart = dialedLocalRestart
        }
    }

    /// The payload regardless of case.
    public var context: Context {
        switch self {
        case let .disconnected(context), let .reconnecting(context):
            return context
        }
    }
}
// Provenance (`displacedNonErrorState` / `dialedLocalRestart`) is excluded from
// equality/hash: nothing renders it, so a provenance-only change must not make
// `remoteReconnect` (and therefore `TerminalPane`) compare unequal and spuriously
// re-render — same rationale as the runtime-field exclusions on `TerminalPane`.
// The confirm/announce paths read the flags directly off the payload, never via
// equality.
extension RemoteReconnectState.Context: Equatable, Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(target)
    }
}
