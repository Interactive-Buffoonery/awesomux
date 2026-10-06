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

    @Test(arguments: ["notes.md", "./next.md", "../next.markdown", "café.md", "cafe\u{301}.md", "文書.md", "notes.md."])
    func acceptsStandaloneNames(_ text: String) {
        #expect(GhosttyMarkdownClickProbe.filename(text, start: 8, length: 10, columns: 12, rows: 4, visible: true) { _ in " " } != nil)
    }

    @Test(arguments: ["notes.md.bak", "https://example.com/a.md", "person@notes.md", "notes\u{202E}.md", "two files.md"])
    func rejectsAmbiguousNames(_ text: String) {
        #expect(GhosttyMarkdownClickProbe.filename(text, start: 8, length: 10, columns: 12, rows: 4, visible: true) { _ in " " } == nil)
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

    @Test(arguments: [" ", "\n", "'", "\"", "`", "(", ")", "[", "]", "", "|"])
    func acceptsDelimiters(_ delimiter: String) {
        #expect(
            GhosttyMarkdownClickProbe.filename("notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true) { _ in delimiter }
                == "notes.md")
    }

    @Test(arguments: ["x", ".", "/", "@", "😀", "文", "\u{301}"])
    func rejectsJoinedNamesOnEitherSide(_ neighbor: String) {
        for blockedCell: UInt64 in [7, 16] {
            #expect(
                GhosttyMarkdownClickProbe.filename("notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true) {
                    $0 == blockedCell ? neighbor : " "
                } == nil)
        }
    }

    @Test func currentFilenameUsesOnlyCurrentTerminalText() {
        #expect(
            GhosttyMarkdownClickProbe.filename(
                "current.md", start: 8, length: 9, columns: 12, rows: 4, visible: true
            ) { _ in " " } == "current.md")
    }

    @Test func explicitHyperlinkLabelKeepsNativeRouting() {
        #expect(
            GhosttyMarkdownClickProbe.filename(
                "notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true, hasNativeLink: true
            ) { _ in " " } == nil)
        var link = GhosttyNativeLinkState()
        link.updatePointer(true)
        #expect(link.isLink)
        #expect(link.value == nil)
        link.updateTarget("https://example.com/different")
        #expect(link.value == "https://example.com/different")
        link.updatePointer(true)
        #expect(link.isLink)
        #expect(link.value == "https://example.com/different")
        link.updatePointer(false)
        #expect(link.isLink)
        #expect(link.value == "https://example.com/different")
        link.updateTarget("")
        #expect(!link.isLink)
        #expect(link.value == nil)
        link.updateTarget("next.md")
        link.updatePointer(true)
        #expect(link.value == "next.md")
        link.updateTarget(nil)
        #expect(link.isLink)
        #expect(link.value == nil)
        link.updatePointer(false)
        #expect(!link.isLink)
    }

    @Test func nonFilenameTextKeepsNativeRouting() {
        #expect(
            GhosttyMarkdownClickProbe.filename(
                "https://example.com/notes.md", start: 8, length: 27, columns: 12, rows: 4, visible: true
            ) { _ in " " } == nil)
    }

    @Test func rejectsFailedCellRead() {
        #expect(
            GhosttyMarkdownClickProbe.filename("notes.md", start: 8, length: 7, columns: 12, rows: 4, visible: true) { _ in nil } == nil)
    }
}
