import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Workspace attention announcement delivery")
struct WorkspaceAttentionAnnouncementDeliveryTests {
    @Test("localized message reaches the accessibility delivery boundary")
    @MainActor
    func localizedMessageReachesPostClosure() throws {
        let bundle = try #require(Self.frenchBundle)
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
            locale: Locale(identifier: "fr")
        ) {
            delivered.append($0)
        }

        #expect(message == "revue attend une réponse de Terminal.")
        #expect(delivered == ["revue attend une réponse de Terminal."])
    }

    private static var frenchBundle: Bundle? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(
                path: "Fixtures/INT612Localization.bundle/fr.lproj",
                directoryHint: .isDirectory
            )
        return Bundle(url: url)
    }
}
