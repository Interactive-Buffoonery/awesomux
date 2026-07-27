import Foundation

/// Claim detectors for destructive-close confirmation copy.
///
/// The close dialogs are pure prose, and the thing worth locking down is which
/// *claim* each variant makes — "awesoMux ends this" versus "this keeps running
/// without awesoMux" — not the sentence that carries it. Asserting through
/// these keeps a future rewording free while still failing the moment a dialog
/// promises to terminate a session the remote host owns.
enum ClosePresentationClaims {
    /// Copy asserting that closing ends the session itself.
    static func claimsDestruction(_ text: String) -> Bool {
        matches(text, #"\b(terminat\w*|kills?|destroys?|shuts? down)\b"#)
    }

    /// Copy asserting that something outlives the close — "keeps running",
    /// "keeps their sessions running", "stay running", and so on, within one
    /// sentence.
    static func saysSomethingKeepsRunning(_ text: String) -> Bool {
        matches(text, #"\b(keeps?|stays?)\b[^.]*\brunning\b"#)
    }

    /// Copy asserting that the pane's work does not come back — either awesoMux
    /// ends it outright, or it survives somewhere awesoMux can no longer reach.
    ///
    /// The reattach half requires a negation ahead of it in the same sentence.
    /// Matching a bare "reattach" made this true for copy claiming the exact
    /// opposite — "you can reattach after closing" would have satisfied an
    /// assertion that the pane is lost, so the guard would have passed on
    /// wording it exists to reject.
    static func saysAwesoMuxLosesThePane(_ text: String) -> Bool {
        claimsDestruction(text)
            || matches(
                text,
                #"\b(?:can'?t|cannot|won'?t|will not|unable to|no longer)\b[^.]*\b(?:reattach\w*|recover\w*)\b"#
            )
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
