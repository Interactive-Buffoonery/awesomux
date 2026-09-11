import AwesoMuxCore
import Foundation
import Observation

struct DocumentFileBrowserRequest: Equatable, Identifiable {
    let id = UUID()
    let sessionID: TerminalSession.ID
    let groupID: DocumentGroup.ID
    let documentID: DocumentPane.ID?
}

@MainActor
@Observable
final class DocumentComposeTabActionHandler {
    private(set) var noticeID: UUID?
    private(set) var fileBrowserRequest: DocumentFileBrowserRequest?

    func perform(
        _ action: () -> Void,
        announce: (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        switch DocumentComposeGuard.tabActionDecision() {
        case .allowed:
            noticeID = nil
            action()
        case .blocked(let message):
            let shouldAnnounce = noticeID == nil
            let newNoticeID = UUID()
            noticeID = newNoticeID
            if shouldAnnounce {
                announce(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.noticeID == newNoticeID {
                    self?.noticeID = nil
                }
            }
        }
    }

    func requestFileBrowser(
        in sessionID: TerminalSession.ID,
        groupID: DocumentGroup.ID,
        documentID: DocumentPane.ID?,
        announce: (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        perform(
            {
                self.fileBrowserRequest = DocumentFileBrowserRequest(
                    sessionID: sessionID,
                    groupID: groupID,
                    documentID: documentID
                )
            }, announce: announce)
    }

    func clearFileBrowserRequest(id: UUID? = nil) {
        guard id == nil || fileBrowserRequest?.id == id else { return }
        fileBrowserRequest = nil
    }
}
