import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct DocumentComposeTabActionHandlerTests {
    private final class FocusWindow: NSWindow {
        var treatsAsKeyWindow = true
        override var isKeyWindow: Bool { treatsAsKeyWindow }
    }

    @Test("only explicit tab navigation publishes a document focus request")
    func documentOpensPreserveFocusUntilUserSelectsTab() throws {
        defer { DocumentComposeGuard.isComposing = { false } }
        DocumentComposeGuard.isComposing = { false }
        let session = TerminalSession(title: "test", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "test", sessions: [session])])
        let handler = DocumentComposeTabActionHandler()
        let first = try #require(store.openDocumentPane(fileURL: URL(fileURLWithPath: "/tmp/first.md"), in: session.id))
        let second = try #require(store.openDocumentPane(fileURL: URL(fileURLWithPath: "/tmp/second.md"), in: session.id))
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.selectedTabID == second)
        #expect(handler.focusRequest == nil)

        #expect(handler.selectTab(first, in: session.id, store: store))
        let request = try #require(handler.focusRequest)
        #expect(request.sessionID == session.id)
        #expect(request.tabID == first)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.selectedTabID == first)

        _ = store.openDocumentPane(fileURL: URL(fileURLWithPath: "/tmp/second.md"), in: session.id)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.selectedTabID == second)
        #expect(handler.focusRequest == request)
        handler.selectTab(second, in: session.id, store: store)
        #expect(handler.focusRequest?.tabID == second)
        #expect(handler.focusRequest?.id != request.id)

        let previousRequest = handler.focusRequest
        DocumentComposeGuard.isComposing = { true }
        #expect(!handler.selectTab(first, in: session.id, store: store))
        #expect(handler.focusRequest == previousRequest)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.selectedTabID == second)
    }

    @Test("user-initiated opens publish a focus request until the viewer consumes it")
    func requestFocusPublishesUntilConsumed() throws {
        defer { DocumentComposeGuard.isComposing = { false } }
        DocumentComposeGuard.isComposing = { false }
        let handler = DocumentComposeTabActionHandler()
        let sessionID = TerminalSession.ID()
        let first = DocumentPane.ID()
        let second = DocumentPane.ID()

        handler.requestFocus(for: first, in: sessionID)
        let request = try #require(handler.focusRequest)
        #expect(request.sessionID == sessionID)
        #expect(request.tabID == first)
        #expect(handler.consumeFocusRequest(in: sessionID, tabID: second) == nil)
        #expect(handler.focusRequest?.id == request.id)
        #expect(handler.consumeFocusRequest(in: sessionID, tabID: first)?.id == request.id)
        #expect(handler.focusRequest == nil)

        DocumentComposeGuard.isComposing = { true }
        handler.requestFocus(for: second, in: sessionID)
        #expect(handler.focusRequest == nil)
    }

    @Test("input before an asynchronous document open drops only its focus request")
    func inputCancelsOnlyItsFocusIntent() throws {
        let handler = DocumentComposeTabActionHandler()
        let window = makeFocusWindow()
        let sessionID = TerminalSession.ID()
        let tabID = DocumentPane.ID()
        let intent = try #require(handler.beginFocusIntent(in: window))

        intent.handleSubsequentInput(try #require(keyDown(in: window)))

        #expect(!handler.requestFocus(for: tabID, in: sessionID, intent: intent))
        #expect(handler.focusRequest == nil)
    }

    @Test("an active asynchronous document open publishes and consumes its focus request")
    func activeFocusIntentTransfersThroughTheFocusRequest() throws {
        let handler = DocumentComposeTabActionHandler()
        let window = makeFocusWindow()
        let sessionID = TerminalSession.ID()
        let tabID = DocumentPane.ID()
        let intent = try #require(handler.beginFocusIntent(in: window))

        #expect(handler.requestFocus(for: tabID, in: sessionID, intent: intent))
        let request = try #require(handler.consumeFocusRequest(in: sessionID, tabID: tabID))
        #expect(request.sessionID == sessionID)
        #expect(request.tabID == tabID)
        #expect(handler.focusRequest == nil)
        #expect(request.intent === intent)
        #expect(intent.isActive)
        request.intent?.cancel()
        #expect(!intent.isActive)
    }

    @Test("input after publication drops a delayed focus request")
    func inputAfterFocusRequestPublicationPreventsConsumption() throws {
        let handler = DocumentComposeTabActionHandler()
        let window = makeFocusWindow()
        let sessionID = TerminalSession.ID()
        let tabID = DocumentPane.ID()
        let intent = try #require(handler.beginFocusIntent(in: window))

        #expect(handler.requestFocus(for: tabID, in: sessionID, intent: intent))
        intent.handleSubsequentInput(try #require(keyDown(in: window)))

        #expect(handler.consumeFocusRequest(in: sessionID, tabID: tabID) == nil)
        #expect(handler.focusRequest == nil)
    }

    @Test("an asynchronous document open drops focus when its origin window loses key status")
    func focusIntentDropsWhenOriginatingWindowLosesKeyStatus() throws {
        let handler = DocumentComposeTabActionHandler()
        let window = makeFocusWindow()
        let intent = try #require(handler.beginFocusIntent(in: window))
        window.treatsAsKeyWindow = false

        #expect(!handler.requestFocus(for: DocumentPane.ID(), in: TerminalSession.ID(), intent: intent))
        #expect(handler.focusRequest == nil)
        #expect(!intent.isActive)
    }

    @Test("an older focus intent cannot clear a newer focus request")
    func staleFocusIntentDoesNotClearNewerRequest() throws {
        let handler = DocumentComposeTabActionHandler()
        let window = makeFocusWindow()
        let sessionID = TerminalSession.ID()
        let firstTabID = DocumentPane.ID()
        let secondTabID = DocumentPane.ID()
        let firstIntent = try #require(handler.beginFocusIntent(in: window))
        #expect(handler.requestFocus(for: firstTabID, in: sessionID, intent: firstIntent))
        let secondIntent = try #require(handler.beginFocusIntent(in: window))
        #expect(handler.requestFocus(for: secondTabID, in: sessionID, intent: secondIntent))

        firstIntent.cancel()

        #expect(handler.consumeFocusRequest(in: sessionID, tabID: firstTabID) == nil)
        #expect(handler.focusRequest?.tabID == secondTabID)
    }

    @Test("view tab actions preserve drafts and coalesce announcements")
    func protectedViewTabActions() throws {
        defer { DocumentComposeGuard.isComposing = { false } }

        let handler = DocumentComposeTabActionHandler()
        var actionCount = 0
        var announcements: [String] = []

        DocumentComposeGuard.isComposing = { false }
        handler.perform({ actionCount += 1 }) { announcements.append($0) }
        #expect(actionCount == 1)
        #expect(handler.noticeID == nil)

        DocumentComposeGuard.isComposing = { true }
        handler.perform({ actionCount += 1 }) { announcements.append($0) }
        let firstNoticeID = try #require(handler.noticeID)
        handler.perform({ actionCount += 1 }) { announcements.append($0) }

        #expect(actionCount == 1)
        #expect(handler.noticeID != firstNoticeID)
        #expect(announcements == [DocumentComposeGuard.tabActionBlockedMessage])
    }

    @Test("allowed action clears an obsolete compose notice")
    func allowedActionClearsNotice() {
        defer { DocumentComposeGuard.isComposing = { false } }

        let handler = DocumentComposeTabActionHandler()
        var actionCount = 0

        DocumentComposeGuard.isComposing = { true }
        handler.perform({ actionCount += 1 }) { _ in }
        #expect(handler.noticeID != nil)

        DocumentComposeGuard.isComposing = { false }
        handler.perform({ actionCount += 1 }) { _ in }

        #expect(actionCount == 1)
        #expect(handler.noticeID == nil)
    }

    @Test("file browser requests target a browser and provide a fresh focus signal")
    func fileBrowserRequestIsTargetedAndComposeGuarded() throws {
        defer { DocumentComposeGuard.isComposing = { false } }

        let handler = DocumentComposeTabActionHandler()
        let sessionID = TerminalSession.ID()
        let groupID = DocumentGroup.ID()
        let documentID = DocumentPane.ID()

        DocumentComposeGuard.isComposing = { false }
        handler.requestFileBrowser(
            in: sessionID,
            groupID: groupID,
            documentID: documentID
        )

        let request = try #require(handler.fileBrowserRequest)
        #expect(request.sessionID == sessionID)
        #expect(request.groupID == groupID)
        #expect(request.documentID == documentID)

        handler.requestFileBrowser(
            in: sessionID,
            groupID: groupID,
            documentID: documentID
        )
        let repeatedRequest = try #require(handler.fileBrowserRequest)
        #expect(repeatedRequest.id != request.id)

        handler.clearFileBrowserRequest(id: request.id)
        #expect(handler.fileBrowserRequest?.id == repeatedRequest.id)
        handler.clearFileBrowserRequest(id: repeatedRequest.id)
        #expect(handler.fileBrowserRequest == nil)

        handler.requestFileBrowser(
            in: sessionID,
            groupID: groupID,
            documentID: nil
        )
        #expect(handler.fileBrowserRequest?.documentID == nil)
        handler.clearFileBrowserRequest()

        DocumentComposeGuard.isComposing = { true }
        handler.requestFileBrowser(
            in: TerminalSession.ID(),
            groupID: DocumentGroup.ID(),
            documentID: DocumentPane.ID()
        ) { _ in }
        #expect(handler.fileBrowserRequest == nil)
    }

    @Test("targeted file browser cleanup preserves an incoming tab request")
    func targetedFileBrowserCleanupPreservesIncomingTabRequest() throws {
        let handler = DocumentComposeTabActionHandler()
        let sessionID = TerminalSession.ID()
        let groupID = DocumentGroup.ID()
        let outgoingDocumentID = DocumentPane.ID()
        let incomingDocumentID = DocumentPane.ID()

        handler.requestFileBrowser(
            in: sessionID,
            groupID: groupID,
            documentID: outgoingDocumentID
        )
        handler.requestFileBrowser(
            in: sessionID,
            groupID: groupID,
            documentID: incomingDocumentID
        )
        let incomingRequest = try #require(handler.fileBrowserRequest)

        handler.clearFileBrowserRequest(
            in: sessionID,
            groupID: groupID,
            documentID: outgoingDocumentID
        )
        #expect(handler.fileBrowserRequest?.id == incomingRequest.id)

        handler.clearFileBrowserRequest(
            in: sessionID,
            groupID: groupID,
            documentID: incomingDocumentID
        )
        #expect(handler.fileBrowserRequest == nil)
    }

    @Test("file browser requests stay pending until their exact target consumes them")
    func fileBrowserRequestsRequireAnExactConsumer() throws {
        let handler = DocumentComposeTabActionHandler()
        let sessionID = TerminalSession.ID()
        let groupID = DocumentGroup.ID()
        let documentID = DocumentPane.ID()

        handler.requestFileBrowser(in: sessionID, groupID: groupID, documentID: documentID)
        let documentRequest = try #require(handler.fileBrowserRequest)

        #expect(
            handler.consumeFileBrowserRequest(
                in: sessionID,
                groupID: groupID,
                documentID: nil
            ) == nil
        )
        #expect(handler.fileBrowserRequest?.id == documentRequest.id)
        #expect(
            handler.consumeFileBrowserRequest(
                in: sessionID,
                groupID: DocumentGroup.ID(),
                documentID: documentID
            ) == nil
        )
        #expect(handler.fileBrowserRequest?.id == documentRequest.id)
        #expect(
            handler.consumeFileBrowserRequest(
                in: TerminalSession.ID(),
                groupID: groupID,
                documentID: documentID
            ) == nil
        )
        #expect(handler.fileBrowserRequest?.id == documentRequest.id)
        #expect(
            handler.consumeFileBrowserRequest(
                in: sessionID,
                groupID: groupID,
                documentID: documentID
            )?.id == documentRequest.id
        )
        #expect(handler.fileBrowserRequest == nil)

        handler.requestFileBrowser(in: sessionID, groupID: groupID, documentID: nil)
        let browserRequest = try #require(handler.fileBrowserRequest)
        #expect(
            handler.consumeFileBrowserRequest(
                in: sessionID,
                groupID: groupID,
                documentID: documentID
            ) == nil
        )
        #expect(handler.fileBrowserRequest?.id == browserRequest.id)
        #expect(
            handler.consumeFileBrowserRequest(
                in: sessionID,
                groupID: groupID,
                documentID: nil
            )?.id == browserRequest.id
        )
        #expect(handler.fileBrowserRequest == nil)
    }

    private func makeFocusWindow() -> FocusWindow {
        _ = NSApplication.shared
        return FocusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func keyDown(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )
    }
}
