import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Workspace attention announcement delivery")
struct WorkspaceAttentionAnnouncementDeliveryTests {
    @Test("localized message reaches the accessibility delivery boundary")
    @MainActor
    func localizedMessageReachesPostClosure() throws {
        let bundle = try #require(Self.pseudoLocaleBundle)
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
            locale: Locale(identifier: "zz")
        ) {
            delivered.append($0)
        }

        #expect(message == "⟦input:revue:⟦Shell⟧⟧")
        #expect(delivered == ["⟦input:revue:⟦Shell⟧⟧"])
    }

    private static var pseudoLocaleBundle: Bundle? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(
                path: "Fixtures/INT612Localization.bundle/zz.lproj",
                directoryHint: .isDirectory
            )
        return Bundle(url: url)
    }
}
