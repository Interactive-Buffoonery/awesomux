import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation

/// The two pane-derived inputs `AgentTranscriptOpener.open` needs and that
/// neither the pane nor the importer can work out for itself: which provider
/// config homes to search, and which session ids already belong to someone
/// else.
///
/// Lifted out of the menu command so both are unit-testable — the command
/// itself is a SwiftUI `App` method, reachable from tests only as source text.
enum AgentTranscriptPaneInputs {

    /// The provider config homes to try for a pane whose agent is `agentKind`,
    /// in order.
    ///
    /// Normally exactly one — the pane's own agent. The exception is `.shell`:
    /// `sessionEnd` resets a pane to `.shell` (`AgentRuntimeEventReducer`), so
    /// the most natural moment to read a transcript back — the agent has just
    /// exited and taken its scrollback with it — is the one moment the pane can
    /// no longer name its provider. Sweeping the providers that keep a readable
    /// log answers that, instead of refusing with a message about the shell.
    ///
    /// Any other kind without a config home genuinely has no readable log, so
    /// it returns empty and the caller keeps its own `.unsupportedAgent` copy.
    ///
    /// Order is presentation only, not precedence: `AgentTranscriptOpener`
    /// resolves every attempt and keeps the most recently modified match, so a
    /// pane where both providers have run resolves to the one the user just
    /// exited rather than to whichever `AgentKind` is declared first.
    ///
    /// ponytail: modification date is the discriminator. Latch the last
    /// non-shell `agentKind` in the runtime event reducer if a pane ever needs
    /// to name its provider after the agent is gone.
    static func resolutionAttempts(
        for agentKind: AgentKind,
        integrations: AgentIntegrationsConfig,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(kind: AgentKind, configHome: URL)] {
        func home(_ kind: AgentKind) -> URL? {
            AgentConfigHome.url(
                for: kind,
                setup: AgentConfigHome.setup(for: kind, in: integrations),
                homeDirectoryURL: homeDirectoryURL
            )
        }
        let kinds: [AgentKind]
        if home(agentKind) != nil {
            kinds = [agentKind]
        } else if agentKind == .shell {
            kinds = AgentConfigHome.kindsWithConfigHome
        } else {
            kinds = []
        }
        return kinds.compactMap { kind in home(kind).map { (kind: kind, configHome: $0) } }
    }

    /// Provider session ids latched to panes other than `paneID`, anywhere in
    /// the store.
    ///
    /// The working-directory fallback's one signal for telling this pane's
    /// session from a neighbour's: two panes in one directory both match on
    /// `cwd`, and the neighbour sorts newest precisely because its agent is
    /// writing right now.
    ///
    /// It covers only a neighbour that has emitted a hook event since the
    /// latch was built, and latches are rebuilt empty on relaunch — so right
    /// after one, two idle reattached agents in one directory exclude nothing
    /// from each other. See `AgentTranscriptImporter.open`'s parameter notes
    /// for the residual that leaves.
    ///
    /// Store-wide rather than session-scoped: a latch is per pane, and panes in
    /// another workspace can share a working directory just as easily.
    @MainActor
    static func sessionIDsLatchedToOtherPanes(
        excluding paneID: TerminalPane.ID,
        in store: SessionStore
    ) -> Set<String> {
        Set(
            store.groups
                .flatMap(\.sessions)
                .flatMap(\.layout.paneIDs)
                .filter { $0 != paneID }
                .compactMap { store.agentProviderSessionID(for: $0) }
        )
    }
}
