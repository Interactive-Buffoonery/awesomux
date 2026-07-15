import Testing
@testable import AwesoMuxCore

@Suite(.serialized)
@MainActor
struct DocumentComposeGuardTests {
    @Test("open annotation draft blocks every document tab attempt with feedback")
    func openDraftBlocksTabAttempts() {
        defer { DocumentComposeGuard.isComposing = { false } }

        #expect(DocumentComposeGuard.tabActionDecision() == .allowed)
        DocumentComposeGuard.isComposing = { true }

        let firstAttempt = DocumentComposeGuard.tabActionDecision()
        let repeatedAttempt = DocumentComposeGuard.tabActionDecision()

        #expect(firstAttempt == .blocked(DocumentComposeGuard.tabActionBlockedMessage))
        #expect(repeatedAttempt == firstAttempt)
    }
}
