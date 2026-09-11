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
}
