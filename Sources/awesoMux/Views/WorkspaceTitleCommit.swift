import AwesoMuxCore

/// What a committed inline workspace-title edit means.
///
/// Two cases, not three: unlike a pane — which has a live terminal-supplied
/// title to fall back to, so blank input there means "reset" — a workspace title
/// has no live source. Blank input is therefore rejected rather than clearing
/// the name, which is why this does not reuse `PaneTitleBarView.resolveCommit`.
enum WorkspaceTitleCommit: Equatable {
    case rename(String)
    case noChange

    /// - blank / whitespace-only → no change (nothing to fall back to)
    /// - sanitizes to the current title → no change (no redundant store write)
    /// - otherwise → rename with the sanitized title
    ///
    /// `nonisolated` so the pure logic is callable off the main actor; the view
    /// is implicitly `@MainActor` and the unit test exercises this directly.
    nonisolated static func resolveWorkspaceTitleCommit(
        input: String,
        current: String
    ) -> WorkspaceTitleCommit {
        let sanitized = SessionStore.sanitizedTitle(input)
        if sanitized.isEmpty {
            return .noChange
        }
        if sanitized == SessionStore.sanitizedTitle(current) {
            return .noChange
        }
        return .rename(sanitized)
    }
}
