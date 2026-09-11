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
    struct FocusRequest: Equatable {
        let id = UUID()
        let sessionID: TerminalSession.ID
        let tabID: DocumentPane.ID
    }

    private(set) var noticeID: UUID?
    private(set) var fileBrowserRequest: DocumentFileBrowserRequest?
    private(set) var focusRequest: FocusRequest?

    @discardableResult
    func selectTab(_ tabID: DocumentPane.ID, in sessionID: TerminalSession.ID, store: SessionStore) -> Bool {
        var didSelect = false
        perform {
            store.selectDocumentTab(tabID: tabID, in: sessionID)
            guard store.session(id: sessionID)?.layout.firstDocumentGroup?.selectedTabID == tabID else { return }
            focusRequest = FocusRequest(sessionID: sessionID, tabID: tabID)
            didSelect = true
        }
        return didSelect
    }

    func requestFocus(for tabID: DocumentPane.ID, in sessionID: TerminalSession.ID) {
        perform {
            self.focusRequest = FocusRequest(sessionID: sessionID, tabID: tabID)
        }
    }

    func consumeFocusRequest(
        in sessionID: TerminalSession.ID,
        tabID: DocumentPane.ID
    ) -> FocusRequest? {
        guard
            let request = focusRequest,
            request.sessionID == sessionID,
            request.tabID == tabID
        else {
            return nil
        }
        focusRequest = nil
        return request
    }

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

    func consumeFileBrowserRequest(
        in sessionID: TerminalSession.ID,
        groupID: DocumentGroup.ID,
        documentID: DocumentPane.ID?
    ) -> DocumentFileBrowserRequest? {
        guard
            let request = fileBrowserRequest,
            request.sessionID == sessionID,
            request.groupID == groupID,
            request.documentID == documentID
        else {
            return nil
        }
        fileBrowserRequest = nil
        return request
    }

    func clearFileBrowserRequest(
        in sessionID: TerminalSession.ID,
        groupID: DocumentGroup.ID,
        documentID: DocumentPane.ID?
    ) {
        _ = consumeFileBrowserRequest(in: sessionID, groupID: groupID, documentID: documentID)
    }
}
