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
}
