import AppKit
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
        let intent: FocusIntent?

        init(
            sessionID: TerminalSession.ID,
            tabID: DocumentPane.ID,
            intent: FocusIntent? = nil
        ) {
            self.sessionID = sessionID
            self.tabID = tabID
            self.intent = intent
        }

        static func == (lhs: FocusRequest, rhs: FocusRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    @MainActor
    final class FocusIntent {
        private weak var window: NSWindow?
        private var inputMonitor: Any?

        init?(in window: NSWindow?) {
            guard let window, window.isKeyWindow, window.attachedSheet == nil else { return nil }
            self.window = window
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handleSubsequentInput(event)
                return event
            }
        }

        var isActive: Bool {
            inputMonitor != nil && window?.isKeyWindow == true && window?.attachedSheet == nil
        }

        func handleSubsequentInput(_ event: NSEvent) {
            if let eventWindow = event.window, eventWindow !== window { return }
            cancel()
        }

        func cancel() {
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
        }

        isolated deinit { cancel() }
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

    func beginFocusIntent(in window: NSWindow? = NSApp.keyWindow) -> FocusIntent? {
        FocusIntent(in: window)
    }

    func requestFocus(for tabID: DocumentPane.ID, in sessionID: TerminalSession.ID) {
        _ = requestFocus(for: tabID, in: sessionID, intent: nil)
    }

    @discardableResult
    func requestFocus(
        for tabID: DocumentPane.ID,
        in sessionID: TerminalSession.ID,
        intent: FocusIntent?
    ) -> Bool {
        var didRequest = false
        perform {
            guard intent?.isActive ?? true else {
                intent?.cancel()
                return
            }
            focusRequest?.intent?.cancel()
            focusRequest = FocusRequest(sessionID: sessionID, tabID: tabID, intent: intent)
            didRequest = true
        }
        return didRequest
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
        guard request.intent?.isActive ?? true else {
            request.intent?.cancel()
            return nil
        }
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
