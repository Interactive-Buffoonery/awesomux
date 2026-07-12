import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct DocumentLayoutTests {
    private func makeDoc() -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "int562-\(UUID().uuidString).md"),
            title: "notes.md"
        )
    }

    private func makeGroup(_ tabs: [DocumentPane]? = nil) -> DocumentGroup {
        let tabs = tabs ?? [makeDoc()]
        return DocumentGroup(tabs: tabs, selectedTabID: tabs[0].id)
    }

    @Test func documentGroupLeafIsInvisibleToTerminalEnumeration() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(makeGroup())
        ))
        #expect(layout.paneIDs == [terminal.id])          // group skipped
        #expect(layout.firstPane?.id == terminal.id)        // group skipped
        #expect(layout.pane(id: terminal.id)?.id == terminal.id)
        // A2: paneCount counts terminal panes only; a terminal+viewer split == 1.
        #expect(layout.paneCount == 1)
        #expect(layout.isSinglePane)
        #expect(!layout.hasMultiplePanes)
    }

    @Test func terminalViewerSplitIsTerminalOnlyForPaneCount() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(makeGroup())
        ))
        // A split containing exactly one terminal and one viewer must read
        // as a single-terminal session for all multi-pane UI gates.
        #expect(layout.paneCount == 1)
        #expect(layout.isSinglePane)
        #expect(!layout.hasMultiplePanes)
    }

    @Test func documentGroupCodableRoundTrip() throws {
        var doc = makeDoc()
        doc.associatedTerminalPaneID = TerminalPane.ID()
        let other = makeDoc()
        let group = DocumentGroup(tabs: [doc, other], selectedTabID: other.id)
        let layout = TerminalPaneLayout.documentGroup(group)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TerminalPaneLayout.self, from: data)
        #expect(decoded == layout)
    }

    @Test func legacyDocumentLeafDecodesAsSingleTabGroup() throws {
        // A v3/v4 snapshot stores `.document(DocumentPane)`. The decoder maps the
        // legacy `document` key to a single-tab group with a nil association
        // (the version-gated session-level migration backfills it later).
        let doc = makeDoc()
        struct LegacyLeaf: Encodable {
            struct Payload: Encodable {
                let value: DocumentPane
                enum CodingKeys: String, CodingKey { case value = "_0" }
            }
            let document: Payload
        }
        let data = try JSONEncoder().encode(LegacyLeaf(document: .init(value: doc)))

        let decoded = try JSONDecoder().decode(TerminalPaneLayout.self, from: data)

        guard case let .documentGroup(group) = decoded else {
            Issue.record("Expected legacy document leaf to decode as a documentGroup")
            return
        }
        #expect(group.tabs.count == 1)
        #expect(group.tabs[0].id == doc.id)
        #expect(group.tabs[0].fileURL == doc.fileURL)
        #expect(group.selectedTabID == doc.id)
        #expect(group.tabs[0].associatedTerminalPaneID == nil)
    }

    @Test func emptyDocumentGroupIsRejectedAtDecode() throws {
        let json = """
        {"documentGroup":{"_0":{"id":"\(UUID().uuidString)","tabs":[],"selectedTabID":"\(UUID().uuidString)"}}}
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TerminalPaneLayout.self, from: Data(json.utf8))
        }
    }

    /// A2: Invariant — a session never reduces to document-only.
    /// Removing the last terminal from a split returns nil (caller closes the session).
    @Test func removingLastTerminalClosesSessionNotLeavesViewer() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical, first: .pane(terminal), second: .documentGroup(makeGroup())
        ))
        // Invariant: never reduce to a viewer-only layout → nil so the caller closes the session.
        #expect(layout.removingPane(id: terminal.id) == nil)
    }

    /// INT-748: the group's tabs each carry their own terminal association, so
    /// removing the terminal that happens to be the group's structural split
    /// sibling must NOT destroy the viewer while other terminals survive. The
    /// ≥1-terminal invariant is enforced at the root only.
    @Test("removing the group's split-sibling terminal preserves the group beside the survivors")
    func removingGroupSiblingTerminalPreservesGroup() throws {
        // Layout after a drag-to-edge rearrangement: .split(.split(t2, G), t1)
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp")
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp")
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(t2),
                second: .documentGroup(group)
            )),
            second: .pane(t1)
        ))

        let result = try #require(layout.removingPane(id: t2.id))

        #expect(result.paneIDs == [t1.id], "t1 survives")
        #expect(
            result.firstDocumentGroup?.id == group.id,
            "the viewer and its tabs survive the sibling terminal's removal"
        )
    }

    /// A2: A standalone group leaf has paneCount == 0 (no terminal panes).
    @Test func documentGroupLeafHasZeroTerminalPaneCount() {
        let layout = TerminalPaneLayout.documentGroup(makeGroup())
        #expect(layout.paneIDs.isEmpty)   // invisible to terminal enumeration
        #expect(layout.paneCount == 0)    // contributes no terminal panes
        #expect(!layout.isSinglePane)
        #expect(!layout.hasMultiplePanes)
    }

    // MARK: - removingDocumentGroup

    @Test("removingDocumentGroup collapses split to terminal sibling")
    func removingDocumentGroupCollapsesToTerminalSibling() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group)
        ))

        let result = try #require(layout.removingDocumentGroup(id: group.id))

        guard case let .pane(survivor) = result else {
            Issue.record("Expected collapsed layout to be a single terminal pane")
            return
        }
        #expect(survivor.id == terminal.id)
    }

    @Test("removingDocumentGroup returns nil for unknown id")
    func removingDocumentGroupReturnsNilForUnknownID() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp")
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(makeGroup())
        ))

        #expect(layout.removingDocumentGroup(id: DocumentGroup.ID()) == nil)
    }

    @Test("removingDocumentGroup in nested split collapses only the owning split")
    func removingDocumentGroupInNestedSplitCollapsesOwningSplit() throws {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp")
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp")
        let group = makeGroup()
        // .split(.pane(t1), .split(.pane(t2), .documentGroup(group)))
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(t1),
            second: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t2),
                second: .documentGroup(group)
            ))
        ))

        let result = try #require(layout.removingDocumentGroup(id: group.id))

        // Outer split should survive; inner split should collapse to t2.
        guard case let .split(root) = result,
              case let .pane(first) = root.first,
              case let .pane(second) = root.second else {
            Issue.record("Expected .split(.pane(t1), .pane(t2)) after removing the group")
            return
        }
        #expect(first.id == t1.id)
        #expect(second.id == t2.id)
    }
}
