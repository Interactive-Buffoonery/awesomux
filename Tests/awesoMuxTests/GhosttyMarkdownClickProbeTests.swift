import AppKit
import Testing
@testable import awesoMux

@Suite @MainActor struct GhosttyMarkdownClickProbeTests {
    @Test func rejectsStalePressPositionAndSurface() {
        let position = CGPoint(x: 10, y: 20)
        #expect(GhosttyMarkdownClickProbe.isCurrent(press: position, reported: position, surface: 1, reportedSurface: 1))
        #expect(!GhosttyMarkdownClickProbe.isCurrent(press: CGPoint(x: 30, y: 20), reported: position, surface: 1, reportedSurface: 1))
        #expect(!GhosttyMarkdownClickProbe.isCurrent(press: position, reported: position, surface: 2, reportedSurface: 1))
        #expect(!GhosttyMarkdownClickProbe.isCurrent(press: position, reported: nil, surface: 1, reportedSurface: nil))
    }

    @Test(arguments: [
        ("notes.md", true), ("./next.md", true), ("../next.markdown", true),
        ("café.md", true), ("cafe\u{301}.md", true), ("文書.md", true), ("notes.md.", true),
        ("notes.md.bak", false), ("https://example.com/a.md", false), ("person@notes.md", false),
        ("notes\u{202E}.md", false), ("two files.md", false),
    ])
    func acceptsStandaloneNames(_ text: String, accepted: Bool) {
        #expect(
            (GhosttyMarkdownClickProbe.filename(text, start: 8, length: 10, columns: 12, rows: 4, visible: true) { _ in " " } != nil)
                == accepted)
    }

    @Test func wrappedWideAndCombiningNamesUseCellOffsets() {
        var cells: [UInt64] = []
        let name = GhosttyMarkdownClickProbe.filename("文cafe\u{301}.md", start: 8, length: 8, columns: 12, rows: 4, visible: true) {
            cells.append($0)
            return " "
        }
        #expect(name == "文cafe\u{301}.md")
        #expect(cells == [7, 17])
    }

    @Test func rejectsClippedAndInvalidOffsetsWithoutReadingCells() {
        for (start, length, columns, rows, visible) in [
            (0, 8, 12, 4, true), (40, 7, 12, 4, true), (48, 0, 12, 4, true),
            (8, 50, 12, 4, true), (8, 0, 12, 4, true), (8, 8, 0, 4, true), (8, 8, 12, 0, true),
            (8, 8, 12, 4, false),
        ] {
            var read = false
            #expect(
                GhosttyMarkdownClickProbe.filename(
                    "notes.md", start: UInt64(start), length: UInt64(length),
                    columns: UInt64(columns), rows: UInt64(rows), visible: visible
                ) { _ in
                    read = true; return " "
                } == nil)
            #expect(!read)
        }
    }

    @Test(arguments: [
        (Optional(" "), true), ("\n", true), ("'", true), ("\"", true), ("`", true),
        ("(", true), (")", true), ("[", true), ("]", true), ("", true), ("|", true),
        ("x", false), (".", false), ("/", false), ("@", false), ("😀", false), ("文", false), ("\u{301}", false), (nil, false),
    ])
    func rejectsJoinedNamesOnEitherSide(_ neighbor: String?, accepted: Bool) {
        if accepted {
            #expect(
                GhosttyMarkdownClickProbe.filename("notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true) { _ in neighbor }
                    == "notes.md")
        }
        for blockedCell: UInt64 in [7, 16] {
            #expect(
                GhosttyMarkdownClickProbe.filename("notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true) {
                    $0 == blockedCell ? neighbor : " "
                } == (accepted ? "notes.md" : nil))
        }
    }

    @Test func explicitHyperlinkLabelKeepsNativeRouting() {
        #expect(
            GhosttyMarkdownClickProbe.filename(
                "notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true, hasNativeLink: true
            ) { _ in " " } == nil)
        var link = GhosttyNativeLinkState()
        link.beginPositionUpdate()
        link.updatePointer(true)
        link.updateTarget("https://example.com/different")
        link.endPositionUpdate()
        #expect(link.isLink)
        #expect(link.value == "https://example.com/different")
        link.updatePointer(false)
        #expect(link.isLink)
        link.beginPositionUpdate()
        link.updateTarget("")
        link.endPositionUpdate()
        #expect(!link.isLink)
        #expect(link.value == nil)
    }

}
