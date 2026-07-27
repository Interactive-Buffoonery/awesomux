import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// Opening a browser result calls `replaceDocumentPane`, which swaps the tab's
/// file **in place**. Picking an over-cap file therefore destroys the current
/// tab's file association and scroll context and only then lands on a full-pane
/// error. These pin the two guards that stop that: the enumerated size marker,
/// and the click-time re-stat that refuses without replacing anything.
@Suite("Document file browser size guard")
struct DocumentFileBrowserSizeGuardTests {

    private func temporaryMarkdownFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-size-guard-\(UUID().uuidString).md")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        // Sparse: only the reported size matters to the cap.
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test("a file within the cap is not refused")
    func withinCapIsNotRefused() throws {
        let url = try temporaryMarkdownFile(bytes: DocumentURLValidator.maxFileSizeBytes)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(DocumentFileBrowserView.refusalMessage(forOpening: url) == nil)
    }

    /// The reason the check cannot live on the enumerated snapshot: the file
    /// grows between the listing and the click. An implementation that trusted
    /// the cached size would return nil on the second call here.
    @Test("a file that grows past the cap after enumeration is refused at click time")
    func growthAfterEnumerationIsRefused() throws {
        let url = try temporaryMarkdownFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = MarkdownFileEntry(url: url, relativePath: "notes.md", fileSizeBytes: 1024)
        #expect(entry.exceedsSizeCap == false)
        #expect(DocumentFileBrowserView.refusalMessage(forOpening: url) == nil)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes + 1))
        try handle.close()

        let message = try #require(DocumentFileBrowserView.refusalMessage(forOpening: url))
        #expect(message.contains(url.lastPathComponent))
        #expect(message.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"))
    }

    @Test("a missing file is not refused for size")
    func missingFileIsNotRefusedForSize() {
        let url = URL(fileURLWithPath: "/tmp/awesomux-does-not-exist-\(UUID().uuidString).md")

        // `nil` size means "unknown", which the validator treats as not-too-large.
        // The pane's own read failure is the right place for this to surface.
        #expect(DocumentFileBrowserView.refusalMessage(forOpening: url) == nil)
    }

    @Test("the over-cap row's accessibility label carries the size state")
    func overCapRowLabelCarriesTheState() {
        let entry = MarkdownFileEntry(
            url: URL(fileURLWithPath: "/tmp/project/huge.md"),
            relativePath: "docs/huge.md",
            fileSizeBytes: DocumentURLValidator.maxFileSizeBytes * 3
        )

        let label = DocumentFileBrowserView.fileRowAccessibilityLabel(
            entry: entry, isCurrent: false)

        #expect(label.contains("Too large"))
        #expect(label.contains("docs/huge.md"))
        #expect(
            label.contains(DocumentFileBrowserView.formattedSize(entry.fileSizeBytes)),
            "the spoken label must carry the same size the marker shows: \(label)")
        #expect(label.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"))
    }

    @Test("an openable row keeps its plain label")
    func openableRowKeepsPlainLabel() {
        let entry = MarkdownFileEntry(
            url: URL(fileURLWithPath: "/tmp/project/plan.md"),
            relativePath: "docs/plan.md",
            fileSizeBytes: 4096
        )

        #expect(
            DocumentFileBrowserView.fileRowAccessibilityLabel(entry: entry, isCurrent: false)
                == "Open docs/plan.md")
        #expect(
            DocumentFileBrowserView.fileRowAccessibilityLabel(entry: entry, isCurrent: true)
                == "Current document, docs/plan.md")
    }

    /// The destructive step is `onOpen`, which the group view wires straight to
    /// `replaceDocumentPane`. The guard only holds while every row funnels
    /// through `open(_:)`; a new row wired directly to `onOpen` would silently
    /// restore the bug and no view-level test in this repo can observe it (a
    /// SwiftUI row exposes no reachable accessibility tree). Pin the call-site
    /// count instead.
    @Test("the browser has exactly one onOpen call site, inside the size guard")
    func onOpenIsCalledOnlyFromTheGuardedPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/DocumentFileBrowserView.swift"),
            encoding: .utf8
        )

        #expect(source.components(separatedBy: "onOpen(").count - 1 == 1)
        let normalized = source.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        #expect(
            normalized.contains(
                "guard let message = Self.refusalMessage(forOpening: entry.url) else { refusal = nil onOpen(entry.url) return }"
            ))
    }

    /// `Resources/Localizable.xcstrings` is not a declared SwiftPM resource, so
    /// under `swift test` `String(localized:)` always falls back to formatting
    /// the source literal — asserting on the rendered text can never catch a
    /// missing catalog entry. Parse the catalog directly instead.
    @Test("the new browser copy has catalog entries")
    func browserCopyIsInTheCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogData = try Data(
            contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        // Shared with the document pane's own too-large error.
        #expect(strings["Can't open %arg: file exceeds the %arg MB size limit."] != nil)
        #expect(strings["Too large to open, %arg, over the %arg MB limit, %arg"] != nil)
    }
}
