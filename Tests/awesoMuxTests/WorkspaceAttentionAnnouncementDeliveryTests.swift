import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Workspace attention announcement delivery")
struct WorkspaceAttentionAnnouncementDeliveryTests {
    @Test("localized message reaches the accessibility delivery boundary")
    @MainActor
    func localizedMessageReachesPostClosure() throws {
        let bundle = try #require(AwesoMuxLocalizationTestSupport.bundle)
        let announcement = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(),
            title: "revue",
            agentKind: .shell,
            state: .needsAttention
        )
        var delivered: [String] = []

        let message = WorkspaceAttentionAnnouncementDelivery.deliver(
            [announcement],
            bundle: bundle,
            locale: AwesoMuxLocalizationTestSupport.pseudoLocale
        ) {
            delivered.append($0)
        }

        #expect(message == "⟦input:revue:⟦Shell⟧⟧")
        #expect(delivered == ["⟦input:revue:⟦Shell⟧⟧"])
    }
}
