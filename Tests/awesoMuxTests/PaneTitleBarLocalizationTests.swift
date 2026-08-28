import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Pane title-bar localization")
struct PaneTitleBarLocalizationTests {
    @Test("context-menu fixed titles resolve from shared localized literals")
    func fixedTitles() {
        #expect(PaneTitleBarStrings.rename == "Rename…")
        #expect(PaneTitleBarStrings.resetToTerminalTitle == "Reset to Terminal Title")
        #expect(PaneTitleBarStrings.moveToNewWorkspace == "Move Pane to New Workspace")
        #expect(PaneTitleBarStrings.color == "Color…")
        #expect(PaneTitleBarStrings.defaultColor == "Default")
    }

    @Test("context-menu fixed and color-child titles exist in the string catalog")
    func catalogCoverage() throws {
        let keys = try AwesoMuxStringCatalog.keys()
        let fixed = [
            "Rename…",
            "Reset to Terminal Title",
            "Move Pane to New Workspace",
            "Color…",
            "Default",
        ]
        let colors = WorkspaceGroupColor.allCases.map(\.displayName)

        #expect(Set(fixed + colors).isSubset(of: keys))
    }
}
