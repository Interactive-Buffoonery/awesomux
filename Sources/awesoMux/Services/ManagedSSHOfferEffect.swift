import AwesoMuxConfig
import AwesoMuxCore

/// What the app does about a detected SSH connection once its one-shot offer
/// has been consumed.
///
/// Extracted from the App's switch so the mapping is reachable from tests. It
/// previously lived inside a `@MainActor` App method that nothing could call,
/// and the test that claimed to cover it re-implemented the two production
/// calls by hand and asserted the policy verdict — so reordering the arms, or
/// presenting the sheet on the suppressed path, left the whole suite green.
enum ManagedSSHOfferEffect: Equatable {
    case doNothing
    case present
    case convert(sessionName: RemoteSessionName?)

    /// `target` is nil when there is no pending offer for this pane, which is
    /// the overwhelmingly common case — every `.task(id:)` firing that is not a
    /// fresh SSH connection lands here.
    static func resolve(target: RemoteTarget?, config: WorkspaceConfig) -> ManagedSSHOfferEffect {
        guard let target else {
            return .doNothing
        }
        switch ManagedSSHOfferPolicy.decision(target: target, config: config) {
        case .none:
            return .doNothing
        case .offer:
            return .present
        case .connectAutomatically(let sessionName):
            return .convert(sessionName: sessionName)
        }
    }
}

/// Turns a resolved effect into the app's three possible actions.
///
/// The actions are injected rather than called inline so a test can assert
/// *which* of them ran. The previous shape put this switch in the App and
/// pinned it with source-text assertions, which a cross-model review defeated
/// in one line: a regression that resolved the effect, discarded it, and
/// switched on a constant instead kept every token those assertions looked
/// for while sending suppressed destinations back to the consent sheet.
enum ManagedSSHOfferEnactor {
    /// `convert` reports whether the pane was actually reconnected. A failure
    /// falls back to the prompt: the offer is one-shot and already consumed by
    /// this point, so doing nothing would drop the destination rather than
    /// defer it.
    static func enact(
        _ effect: ManagedSSHOfferEffect,
        convert: (RemoteSessionName?) -> Bool,
        present: () -> Void,
        confirm: () -> Void
    ) {
        switch effect {
        case .doNothing:
            return
        case .present:
            present()
        case .convert(let sessionName):
            if convert(sessionName) {
                confirm()
            } else {
                present()
            }
        }
    }
}
