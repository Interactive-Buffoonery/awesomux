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
        let cap = DocumentURLValidator.maxFileSizeBytes / (1024 * 1024)

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
}
