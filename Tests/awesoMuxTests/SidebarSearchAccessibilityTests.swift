import Foundation
import Testing

@Suite("Sidebar search accessibility")
struct SidebarSearchAccessibilityTests {
    @Test("Expanded search exposes the same help visually and to assistive technology")
    func expandedSearchHelpContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/awesoMux/Views/SidebarView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains(".accessibilityHint(searchHelp)"))
        #expect(source.contains(".help(searchHelp)"))
    }
}
