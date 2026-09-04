import AwesoMuxCore
import Foundation

/// Applies a render to the initiating pane's current workspace without an await
/// between resolving ownership and opening the tab.
@MainActor
enum AgentTranscriptCompletion {
    static func apply(
        _ result: Result<OpenedAgentTranscript, AgentTranscriptOpenFailure>,
        paneID: TerminalPane.ID,
        store: SessionStore,
        completeWrite: (URL) -> Void,
        schedulePrune: () -> Void,
        alert: (AgentTranscriptOpenFailure) -> Void
    ) {
        switch result {
        case .success(let opened):
            defer {
                completeWrite(opened.fileURL)
                schedulePrune()
            }
            guard let ownerID = store.sessionIDContainingPane(paneID) else {
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "The pane closed before the transcript could open.",
                        comment: "VoiceOver announcement when the initiating pane closes during transcript rendering"
                    )
                )
                return
            }
            guard
                store.openDocumentPane(
                    fileURL: opened.fileURL,
                    in: ownerID,
                    associatedWith: paneID,
                    agentTranscriptIdentity: opened.identity
                ) != nil
            else {
                // The workspace went away while the transcript rendered.
                // No alert — there is nothing left to act on, and the user
                // closed it themselves — but silence would read as a dead
                // command to anyone listening.
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "The workspace closed before the transcript could open.",
                        comment: "VoiceOver announcement when a rendered transcript has no workspace left to open into"
                    )
                )
                return
            }
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "\(opened.identity.agentKind.displayName) transcript opened.",
                    comment: "VoiceOver announcement after a rendered agent transcript opens in a document tab"
                )
            )
        case .failure(let failure):
            alert(failure)
        }
    }
}
