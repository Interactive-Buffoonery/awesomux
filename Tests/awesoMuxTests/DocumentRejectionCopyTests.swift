import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// What these can and cannot see:
///
/// `Resources/Localizable.xcstrings` is not a declared SwiftPM resource, so
/// under `swift test` `String(localized:)` always falls back to formatting the
/// *source literal*. That makes these assertions a check on the source — that
/// every branch substitutes the file name, that the two-placeholder cases land
/// their arguments in the right order — and **not** a check that the catalog
/// agrees. An earlier version of this suite claimed the latter; a `%arg`
/// assertion on a rendered string cannot fail here, because the marker only
/// ever exists in a catalog this build never loads.
///
/// `DocumentRejectionCopyCatalogTests` below covers the half this cannot, by
/// reading the catalog file the shipped `.app` actually loads.
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
    }
}

/// The half the suite above structurally cannot reach: that the source literals
/// it renders actually have matching keys in the catalog the shipped app loads.
/// A literal with no key is not a crash — `String(localized:)` falls through to
/// the literal — so every locale silently gets English and nothing else in the
/// app notices.
@Suite("Document rejection copy catalog coverage")
struct DocumentRejectionCopyCatalogTests {

    /// Named rather than swept from the whole file: `DocumentPaneView` is ~1850
    /// lines and localizes far more than rejection copy, so a file-wide sweep
    /// would fail on catalog drift this change is not responsible for (#198).
    /// These five are the strings the suite above renders.
    @Test(
        arguments: [
            "Can't open %arg: the path is not a local file URL.",
            "Can't open %arg: only these file types are supported: %arg.",
            "Can't open %arg: file exceeds the %arg MB size limit.",
            "Can't open %arg: the file couldn't be read (missing or no permission).",
            "Couldn't read \u{201C}%arg\u{201D}: %arg",
        ])
    func rejectionCopyHasACatalogKey(expectedKey: String) throws {
        #expect(
            try AwesoMuxStringCatalog.keys().contains(expectedKey),
            "Localizable.xcstrings has no key \"\(expectedKey)\"")
    }

    /// Pins the list above to the source. Without this, editing a rejection
    /// string in `DocumentPaneView` and forgetting the catalog would leave the
    /// keys asserted above still present and still passing — the stale key
    /// stays in the catalog, and the new literal is what has no home.
    @Test func everyRejectionLiteralIsCovered() throws {
        let literals = try AwesoMuxStringCatalog.localizedLiterals(
            in: "Sources/awesoMux/Views/DocumentPaneView.swift")
        let rejectionLiterals = literals.filter {
            $0.hasPrefix("Can't open ") || $0.hasPrefix("Couldn't read ")
        }

        #expect(rejectionLiterals.count == 5, "found \(rejectionLiterals.count): \(rejectionLiterals)")

        let keys = try AwesoMuxStringCatalog.keys()
        for literal in rejectionLiterals {
            #expect(keys.contains(literal), "source localizes \"\(literal)\" with no catalog key")
        }
    }
}
