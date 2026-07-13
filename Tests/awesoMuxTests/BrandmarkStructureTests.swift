import Foundation
import Testing

@Suite("Brandmark structure")
struct BrandmarkStructureTests {
    @Test("brandmark keeps icon before title text")
    func iconPrecedesTitle() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/Brandmark.swift"),
            encoding: .utf8
        )
        let icon = try #require(source.range(of: "ShrugMark("))
        let title = try #require(source.range(of: "Text(\"awesoMux\")"))
        #expect(icon.lowerBound < title.lowerBound)
    }
}
