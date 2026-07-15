import Foundation
import Testing

@Suite("Document pointer targets")
struct DocumentPointerTargetTests {
    @Test("annotation actions and compact revision marker use 24 point rectangular targets")
    func documentIconButtonsUseMinimumTargets() throws {
        let commentPopover = try Self.source("Views/Markdown/CommentPopover.swift")
        let resolve = try Self.block(
            from: "Button {\n                        onSetStatus",
            through: ".accessibilityLabel(isResolved ? \"Reopen annotation\" : \"Mark annotation resolved\")",
            in: commentPopover
        )
        let edit = try Self.block(
            from: "Button {\n                        draft = annotation.payload",
            through: ".accessibilityLabel(\"Edit annotation\")",
            in: commentPopover
        )
        let delete = try Self.block(
            from: "Button(role: .destructive, action: onDelete)",
            through: ".accessibilityLabel(\"Delete annotation\")",
            in: commentPopover
        )
        let reply = try Self.block(
            from: "Button(action: submitReply)",
            through: ".accessibilityLabel(\"Send reply\")",
            in: commentPopover
        )
        Self.expectMinimumTarget(resolve)
        Self.expectMinimumTarget(edit)
        Self.expectMinimumTarget(delete)
        Self.expectMinimumTarget(reply)

        let tabStrip = try Self.source("Views/DocumentTabStripView.swift")
        let marker = try Self.block(
            from: "return Button(action: onRevealRevision)",
            through: ".accessibilityHint(",
            in: tabStrip
        )
        Self.expectMinimumTarget(marker)
    }

    @Test("document tab mutations share the compose guard and notice uses opacity")
    func protectedTabWiringAndTransition() throws {
        let groupView = try Self.source("Views/DocumentGroupView.swift")
        let selection = try Self.block(from: "onSelectTab:", through: "onCloseTab:", in: groupView)
        #expect(selection.contains("documentTabActions.perform"))

        let close = try Self.block(from: "onCloseTab:", through: "onExpandRevision:", in: groupView)
        #expect(close.contains("if tab.id == group.selectedTabID"))
        #expect(close.contains("documentTabActions.perform(closeTab)"))
        #expect(close.contains("else {\n                        closeTab()"))

        let revision = try Self.block(from: "onExpandRevision:", through: "onDismissRevision:", in: groupView)
        #expect(revision.contains("if tab.id == group.selectedTabID"))
        #expect(revision.contains("documentTabActions.perform"))

        let app = try Self.source("App/AwesoMuxApp.swift")
        let notice = try Self.block(
            from: "if documentTabActions.noticeID != nil",
            through: ".padding(.top, 18)",
            in: app
        )
        #expect(notice.contains(".transition(.opacity)"))
        #expect(!notice.contains(".move(edge:"))
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

    private static func block(from start: String, through end: String, in source: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return source[startRange.lowerBound..<endRange.upperBound]
    }

    private static func expectMinimumTarget(_ block: Substring) {
        #expect(block.contains(".frame(width: 24, height: 24)"))
        #expect(block.contains(".contentShape(Rectangle())"))
    }
}
