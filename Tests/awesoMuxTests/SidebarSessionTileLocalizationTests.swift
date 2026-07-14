import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar session tile localization")
struct SidebarSessionTileLocalizationTests {
    @Test("the tile's workspace identity resolves through the selected bundle")
    @MainActor
    func tileIdentityUsesLocalizedFormatter() throws {
        let bundle = try #require(AwesoMuxLocalizationTestSupport.bundle)
        let session = TerminalSession(
            title: "build",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )

        #expect(
            SidebarSessionTile.workspaceIdentityAccessibilityLabel(
                session: session,
                rollup: session.agentRollup(),
                bundle: bundle,
                locale: AwesoMuxLocalizationTestSupport.pseudoLocale
            ) == "⟦⟦idle⟧:build:⟦Shell⟧⟧")
    }

    @Test("the tile localizes a synthetic title with the selected locale")
    @MainActor
    func tileIdentityUsesSelectedLocaleForSyntheticTitle() throws {
        let bundle = try #require(AwesoMuxLocalizationTestSupport.bundle)
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 2)
        let session = TerminalSession(
            title: syntheticTitle.canonicalTitle,
            workingDirectory: "~",
            syntheticTitle: syntheticTitle,
            agentKind: .shell
        )

        #expect(
            SidebarSessionTile.workspaceIdentityAccessibilityLabel(
                session: session,
                rollup: session.agentRollup(),
                bundle: bundle,
                locale: AwesoMuxLocalizationTestSupport.pseudoLocale
            ) == "⟦⟦idle⟧:⟦2:⟦shell⟧⟧:⟦Shell⟧⟧")
    }
}
