import Foundation
import Testing
@testable import DesignSystem

@Suite("INT-612 localization")
struct INT612LocalizationTests {
    @Test("agent tile resolves and reorders its spoken label")
    @MainActor
    func agentTileUsesExplicitBundleAndLocale() throws {
        let bundle = try #require(Self.bundle)

        #expect(
            AgentTile.accessibilityLabel(
                agent: .shell,
                state: .running,
                bundle: bundle,
                locale: Locale(identifier: "zz")
            ) == "⟦⟦running⟧:⟦Shell⟧⟧")
    }

    private static var bundle: Bundle? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/INT612Localization.bundle/zz.lproj", directoryHint: .isDirectory)
        return Bundle(url: url)
    }
}
