import Foundation
import Testing

@Suite("Document pointer targets")
struct DocumentPointerTargetTests {
    @Test("annotation actions and compact revision marker use 24 point rectangular targets")
    func documentIconButtonsUseMinimumTargets() throws {
        let commentPopover = try Self.source("Views/Markdown/CommentPopover.swift")
        for label in [
            ".help(isResolved ? \"Reopen\" : \"Mark resolved\")",
            ".accessibilityLabel(\"Edit annotation\")",
            ".accessibilityLabel(\"Delete annotation\")",
            ".accessibilityLabel(\"Send reply\")",
        ] {
            let control = try Self.modifiers(before: label, in: commentPopover)
            #expect(control.contains(".frame(width: 24, height: 24)"))
            #expect(control.contains(".contentShape(Rectangle())"))
        }

        let tabStrip = try Self.source("Views/DocumentTabStripView.swift")
        let marker = try #require(tabStrip.range(of: "private func revisionMarker"))
        let markerEnd = try #require(tabStrip.range(of: "private var titleColor", range: marker.upperBound..<tabStrip.endIndex))
        let markerSource = tabStrip[marker.lowerBound..<markerEnd.lowerBound]
        #expect(markerSource.contains(".frame(width: 24, height: 24)"))
        #expect(markerSource.contains(".contentShape(Rectangle())"))
    }

    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/\(relativePath)"),
            encoding: .utf8
        )
    }

    private static func modifiers(before label: String, in source: String) throws -> Substring {
        let labelRange = try #require(source.range(of: label))
        let start =
            source.index(labelRange.lowerBound, offsetBy: -400, limitedBy: source.startIndex)
            ?? source.startIndex
        return source[start..<labelRange.lowerBound]
    }
}
