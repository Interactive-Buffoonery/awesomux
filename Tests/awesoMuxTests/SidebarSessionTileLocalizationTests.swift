import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar session tile localization")
struct SidebarSessionTileLocalizationTests {
    @Test("the tile's workspace identity resolves through the selected bundle")
    @MainActor
    func tileIdentityUsesLocalizedFormatter() throws {
        let bundle = try #require(Self.frenchBundle)
        let session = TerminalSession(
            title: "build",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )

        #expect(SidebarSessionTile.workspaceIdentityAccessibilityLabel(
            session: session,
            rollup: session.agentRollup(),
            bundle: bundle,
            locale: Locale(identifier: "fr")
        ) == "Inactif — build — Terminal")
    }

    @Test("the tile localizes a synthetic title with the selected locale")
    @MainActor
    func tileIdentityUsesSelectedLocaleForSyntheticTitle() throws {
        let bundle = try #require(Self.frenchBundle)
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 2)
        let session = TerminalSession(
            title: syntheticTitle.canonicalTitle,
            workingDirectory: "~",
            syntheticTitle: syntheticTitle,
            agentKind: .shell
        )

        #expect(SidebarSessionTile.workspaceIdentityAccessibilityLabel(
            session: session,
            rollup: session.agentRollup(),
            bundle: bundle,
            locale: Locale(identifier: "fr")
        ) == "Inactif — 2 coquille — Terminal")
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
