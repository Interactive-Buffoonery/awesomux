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
        private weak var dismissingSheet: NSWindow?
        private weak var initiatingEvent: NSEvent?
        private var inputMonitor: Any?
        private var windowObservers: [NSObjectProtocol] = []
        private let isContextCurrent: (@MainActor () -> Bool)?
        let waitsForSheetDismissal: Bool

        init?(in window: NSWindow?) {
            guard let window, window.isKeyWindow, window.attachedSheet == nil else { return nil }
            self.window = window
            waitsForSheetDismissal = false
            isContextCurrent = nil
            installInputMonitor()
        }

        init?(
            dismissingSheetIn window: NSWindow?,
            initiatingEvent: NSEvent?,
            isContextCurrent: @escaping @MainActor () -> Bool
        ) {
            guard let window, let sheet = window.attachedSheet,
                sheet.sheetParent === window, NSApp.isActive,
                NSApp.keyWindow == nil || NSApp.keyWindow === window || NSApp.keyWindow === sheet,
                NSApp.modalWindow == nil || NSApp.modalWindow === sheet
            else { return nil }
            self.window = window
            dismissingSheet = sheet
            self.initiatingEvent = initiatingEvent
            self.isContextCurrent = isContextCurrent
            waitsForSheetDismissal = true
            installInputMonitor()
            observeSheetTransition()
        }

        var targetWindow: NSWindow? { window }

        private func installInputMonitor() {
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handleSubsequentInput(event)
                return event
            }
        }

        var isActive: Bool {
            guard waitsForSheetDismissal else {
                return inputMonitor != nil && window?.isKeyWindow == true && window?.attachedSheet == nil
            }
            guard inputMonitor != nil, let window, NSApp.isActive, isContextCurrent?() == true else { return false }
            let originalSheetIsAttached =
                dismissingSheet != nil
                && window.attachedSheet === dismissingSheet
            // A closing sheet can remain key after detaching. Readiness still
            // requires the content window to be key and free of any modal.
            return (window.attachedSheet == nil || originalSheetIsAttached)
                && (NSApp.keyWindow == nil || NSApp.keyWindow === window
                    || (dismissingSheet != nil && NSApp.keyWindow === dismissingSheet))
                && (NSApp.modalWindow == nil
                    || (dismissingSheet != nil && NSApp.modalWindow === dismissingSheet))
        }

        var isReadyForHandoff: Bool {
            isActive && window?.isKeyWindow == true && window?.attachedSheet == nil && NSApp.modalWindow == nil
        }

        func handleSubsequentInput(_ event: NSEvent) {
            if waitsForSheetDismissal {
                if event === initiatingEvent { return }
                if let eventWindow = event.window,
                    eventWindow !== window && eventWindow !== dismissingSheet
                {
                    return
                }
            } else if let eventWindow = event.window, eventWindow !== window {
                return
            }
            cancel()
        }

        func cancel() {
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers = []
        }

        private func observeSheetTransition() {
            let center = NotificationCenter.default
            for name in [NSWindow.willBeginSheetNotification, NSWindow.willCloseNotification] {
                windowObservers.append(
                    center.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { [weak self] notification in
                        nonisolated(unsafe) let notification = notification
                        MainActor.assumeIsolated {
                            guard let self, let window = self.window,
                                notification.object as? NSWindow === window
                            else { return }
                            self.cancel()
                        }
                    })
            }
            windowObservers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    nonisolated(unsafe) let notification = notification
                    MainActor.assumeIsolated {
                        guard let self, let activatedWindow = notification.object as? NSWindow else { return }
                        if activatedWindow !== self.window && activatedWindow !== self.dismissingSheet {
                            self.cancel()
                        }
                    }
                })
            windowObservers.append(
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                })
        }

        isolated deinit { cancel() }
    }

    private(set) var noticeID: UUID?
    private(set) var fileBrowserRequest: DocumentFileBrowserRequest?
    private(set) var focusRequest: FocusRequest?
    @ObservationIgnored private weak var sheetFocusIntent: FocusIntent?
    @ObservationIgnored private var sheetFocusSelection: FocusRequest?

    @discardableResult
    func selectTab(_ tabID: DocumentPane.ID, in sessionID: TerminalSession.ID, store: SessionStore) -> Bool {
        var didSelect = false
        perform {
            sheetFocusIntent?.cancel()
            sheetFocusSelection = nil
            store.selectDocumentTab(tabID: tabID, in: sessionID)
            guard store.session(id: sessionID)?.layout.firstDocumentGroup?.selectedTabID == tabID else { return }
            focusRequest = FocusRequest(sessionID: sessionID, tabID: tabID)
            didSelect = true
        }
        return didSelect
    }

    func beginFocusIntent(in window: NSWindow? = NSApp.keyWindow) -> FocusIntent? {
        sheetFocusIntent?.cancel()
        sheetFocusSelection = nil
        return FocusIntent(in: window)
    }

    func beginFocusIntentDismissingSheet(
        in window: NSWindow?,
        initiatingEvent: NSEvent?,
        isContextCurrent: @escaping @MainActor () -> Bool
    ) -> FocusIntent? {
        sheetFocusIntent?.cancel()
        sheetFocusSelection = nil
        let intent = FocusIntent(
            dismissingSheetIn: window, initiatingEvent: initiatingEvent, isContextCurrent: isContextCurrent
        )
        sheetFocusIntent = intent
        return intent
    }

    func requestFocus(for tabID: DocumentPane.ID, in sessionID: TerminalSession.ID) {
        _ = requestFocus(for: tabID, in: sessionID, intent: nil)
    }

    @discardableResult
    func requestFocusAfterSheet(
        for tabID: DocumentPane.ID,
        in sessionID: TerminalSession.ID,
        intent: FocusIntent?
    ) -> Bool {
        // Missing or canceled intent must not regain focus through the
        // viewer's independent follow-document-chrome behavior.
        sheetFocusSelection = FocusRequest(sessionID: sessionID, tabID: tabID)
        guard let intent, intent.waitsForSheetDismissal else { return false }
        return requestFocus(for: tabID, in: sessionID, intent: intent)
    }

    @discardableResult
    func requestFocus(
        for tabID: DocumentPane.ID,
        in sessionID: TerminalSession.ID,
        intent: FocusIntent?
    ) -> Bool {
        var didRequest = false
        perform {
            if sheetFocusIntent !== intent { sheetFocusIntent?.cancel() }
            if intent?.waitsForSheetDismissal != true { sheetFocusSelection = nil }
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

    func selectionHasSheetFocusIntent(for tabID: DocumentPane.ID?, in sessionID: TerminalSession.ID) -> Bool {
        guard let selection = sheetFocusSelection, selection.sessionID == sessionID else { return false }
        guard selection.tabID == tabID else {
            sheetFocusSelection = nil
            return false
        }
        return true
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
