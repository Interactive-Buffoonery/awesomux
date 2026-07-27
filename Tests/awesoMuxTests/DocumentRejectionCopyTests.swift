import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// The document pane's rejection copy resolves through `Localizable.xcstrings`,
/// whose keys carry `%arg` placeholder markers rather than printf specifiers.
/// A source string whose catalog key does not match, or an entry grafted with
/// the wrong shape, surfaces those markers — or an unsubstituted placeholder —
/// directly to the user. Nothing else in the app fails when that happens: the
/// view renders whatever string it is handed.
///
/// These assert the *rendered* text, not the literals, so they fail if the
/// catalog and the source ever disagree.
@Suite("Document rejection copy")
struct DocumentRejectionCopyTests {
    private let pane = DocumentPane(
        fileURL: URL(fileURLWithPath: "/tmp/quarterly-plan.md"),
        title: "quarterly-plan.md")

    @Test(
        "every rejection reason renders without leaking a placeholder marker",
        arguments: [
            DocumentURLValidator.Rejection.notFileURL,
            .badExtension,
            .tooLarge,
            .unreadable,
        ])
    func rejectionCopyLeaksNoPlaceholders(reason: DocumentURLValidator.Rejection) {
        let message = DocumentPaneView.rejectionMessage(for: reason, pane: pane)

        #expect(!message.isEmpty)
        #expect(!message.contains("%arg"), "catalog placeholder marker reached the user: \(message)")
        #expect(!message.contains("%@"), "unsubstituted specifier reached the user: \(message)")
        #expect(!message.contains("%lld"), "unsubstituted specifier reached the user: \(message)")
        #expect(
            message.contains(pane.title),
            "the message should name the file it is about: \(message)")
    }

    /// The size message is the one this cap change makes common, and it is the
    /// only one carrying two substitutions — the case most likely to break if a
    /// catalog entry's positional arguments are wrong.
    @Test("the size rejection states the actual cap")
    func sizeRejectionStatesTheCap() {
        let message = DocumentPaneView.rejectionMessage(for: .tooLarge, pane: pane)
        let cap = DocumentURLValidator.maxFileSizeMegabytes

        #expect(message.contains("\(cap) MB"), "expected the cap in megabytes: \(message)")
        #expect(message.contains(pane.title))
    }

    /// The extension list is interpolated from `allowedExtensions`, so this also
    /// catches the two substitutions landing in the wrong order.
    @Test("the extension rejection lists the supported extensions")
    func extensionRejectionListsExtensions() {
        let message = DocumentPaneView.rejectionMessage(for: .badExtension, pane: pane)

        for ext in DocumentURLValidator.allowedExtensions {
            #expect(message.contains(ext), "expected \(ext) in: \(message)")
        }
    }

    /// `.readError` frames a reason produced by `DocumentLoader`. Both halves
    /// are localized, and the risk is that they drift — a localized frame
    /// wrapping an English payload reads worse than leaving both alone.
    @Test("a read failure names the file and carries the reason through intact")
    func readErrorCarriesTheReason() {
        let reason = DocumentLoader.LoadResult.readError("REASON-SENTINEL")
        guard case let .readError(text) = reason else { return }
        let message = DocumentPaneView.readErrorMessage(text, pane: pane)

        #expect(message.contains(pane.title), "should name the file: \(message)")
        #expect(message.contains("REASON-SENTINEL"), "should carry the reason: \(message)")
        #expect(!message.contains("%arg"), "placeholder marker leaked: \(message)")
    }

    /// The reasons `DocumentLoader` actually produces must themselves resolve —
    /// if one were left as a raw literal it would still render, so assert they
    /// are non-empty and free of markers rather than assuming.
    @Test("the loader's own read-failure reasons render as text")
    func loaderReasonsRender() throws {
        let url = URL(fileURLWithPath: "/tmp/awesomux-not-utf8.md")
        try Data([0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case let .readError(reason) = DocumentLoader.load(url) else {
            Issue.record("expected a read error for non-UTF-8 content")
            return
        }
        #expect(!reason.isEmpty)
        #expect(!reason.contains("%arg"), "placeholder marker leaked: \(reason)")
    }
}
