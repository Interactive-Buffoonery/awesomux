import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct DocumentComposeTabActionHandlerTests {
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
}
