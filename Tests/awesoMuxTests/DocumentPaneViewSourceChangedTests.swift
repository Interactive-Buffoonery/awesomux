import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("DocumentPaneView.sourceChanged")
struct DocumentPaneViewSourceChangedTests {
    private func makeDoc(source: String) -> RenderedDocument {
        RenderedDocument(
            source: source,
            runs: [],
            annotations: [],
            taskProgress: TaskProgress(done: 0, total: 0)
        )
    }

    @Test("identical sources do not report")
    func identicalSourcesAreUnchanged() {
        #expect(!DocumentPaneView.sourceChanged(makeDoc(source: "# same"), makeDoc(source: "# same")))
    }

    @Test("differing sources report")
    func differingSourcesChanged() {
        #expect(DocumentPaneView.sourceChanged(makeDoc(source: "# old"), makeDoc(source: "# new")))
    }

    @Test("a nil new document reports")
    func nilNewDocChanged() {
        // Error reloads carry doc == nil and must keep reporting so the cache
        // stops seeding content the disk can no longer back.
        #expect(DocumentPaneView.sourceChanged(nil, makeDoc(source: "# gone")))
    }

    @Test("a nil prior document reports")
    func nilPriorDocChanged() {
        #expect(DocumentPaneView.sourceChanged(makeDoc(source: "# first"), nil))
    }

    @Test("both documents nil reports")
    func bothNilChanged() {
        #expect(DocumentPaneView.sourceChanged(nil, nil))
    }

    @Test("canonically equivalent sources with different bytes report")
    func canonicallyEquivalentButByteDifferentSourcesChanged() {
        // NFC "é" vs NFD "e" + combining acute: `String ==` calls these equal,
        // but DocumentLoader byte-compares sources when deciding to rebuild, so
        // a normalization-form rewrite must reach the tab cache as changed or
        // the stale render is reseeded on every remount. This is the test that
        // fails under a `String !=` implementation.
        #expect(DocumentPaneView.sourceChanged(makeDoc(source: "caf\u{E9}"), makeDoc(source: "cafe\u{301}")))
        #expect(DocumentPaneView.sourceChanged(makeDoc(source: "cafe\u{301}"), makeDoc(source: "caf\u{E9}")))
        // Byte-identical NFD copies stay unchanged — the comparison is bytes,
        // not "anything normalized differs".
        #expect(!DocumentPaneView.sourceChanged(makeDoc(source: "cafe\u{301}"), makeDoc(source: "cafe\u{301}")))
    }
}
