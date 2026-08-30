import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct OpenDocumentPaneTests {
    private func openTab(
        _ path: String,
        associatedWith paneID: TerminalPane.ID? = nil,
        in session: TerminalSession
    ) -> (session: TerminalSession, newTabID: DocumentPane.ID)? {
        PaneLayoutReducer.openDocumentTab(
            fileURL: URL(fileURLWithPath: path),
            associatedTerminalPaneID: paneID,
            in: session,
            now: Date()
        )
    }

    @Test func insertsDocumentGroupWithoutStealingActivePane() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let updated = try! #require(openTab("/tmp/notes.md", in: session)).session
        #expect(updated.activePaneID == terminal.id)         // terminal keeps focus
        // A2: paneCount counts terminal panes only; a terminal+doc split == 1.
        #expect(updated.layout.paneCount == 1)
        #expect(updated.layout.isSinglePane)                 // treated as single-terminal
        #expect(!updated.layout.hasMultiplePanes)            // no multi-pane chrome
        #expect(updated.layout.paneIDs == [terminal.id])     // docs invisible to terminal enum
        let group = try! #require(updated.layout.firstDocumentGroup)
        #expect(group.tabs.count == 1)
    }

    // MARK: - Same-file dedup (INT-562, retargeted to tabs in INT-748)

    @Test func openingAlreadyOpenFileReturnsSameIDWithoutDuplicate() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, firstID) = try! #require(openTab("/tmp/notes.md", in: session))

        let (secondSession, secondID) = try! #require(openTab("/tmp/notes.md", in: firstSession))

        #expect(secondID == firstID, "dedup must return the existing tab's ID")
        let group = try! #require(secondSession.layout.firstDocumentGroup)
        #expect(group.tabs.count == 1, "no second tab should be inserted")
        #expect(secondSession.layout == firstSession.layout, "layout must be identical after dedup")
    }

    @Test func openingAlreadyOpenFileViaPathVariantDedups() {
        // Verify that /a/./b.md and /a/b.md compare equal via standardizedFileURL.
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, firstID) = try! #require(openTab("/tmp/notes.md", in: session))
        let (secondSession, secondID) = try! #require(openTab("/tmp/./notes.md", in: firstSession))

        #expect(secondID == firstID, "dot-path variant must dedup to the existing tab")
        #expect(secondSession.layout == firstSession.layout, "layout unchanged on dedup")
    }

    @Test func openingDedupedFileSelectsItsTab() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (first, firstID) = try! #require(openTab("/tmp/notes.md", in: session))
        let (second, _) = try! #require(openTab("/tmp/other.md", in: first))

        let (reopened, reopenedID) = try! #require(openTab("/tmp/notes.md", in: second))
        #expect(reopenedID == firstID)
        let group = try! #require(reopened.layout.firstDocumentGroup)
        #expect(group.selectedTabID == firstID, "reopening an open file selects its existing tab")
        #expect(group.tabs.count == 2)
    }

    @Test func openingDifferentFileAppendsTabToSameGroup() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, firstID) = try! #require(openTab("/tmp/notes.md", in: session))
        let (secondSession, secondID) = try! #require(openTab("/tmp/other.md", in: firstSession))

        #expect(secondID != firstID, "different file must produce a distinct tab ID")
        let group = try! #require(secondSession.layout.firstDocumentGroup)
        #expect(group.tabs.count == 2, "second file becomes a second tab in the SAME group")
        #expect(group.selectedTabID == secondID, "newly opened tab is selected")
        // The layout gains no second split for the second document: still one
        // viewer leaf beside the terminal.
        guard case let .split(split) = secondSession.layout else {
            Issue.record("expected a single terminal|viewer split at the root")
            return
        }
        #expect(split.first == .pane(terminal))
        #expect(split.second == .documentGroup(group))
    }

    @Test func openingDocumentTabStoresStandardizedURL() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let dotVariant = URL(fileURLWithPath: "/tmp/./notes.md")
        let (updated, tabID) = try! #require(openTab("/tmp/./notes.md", in: session))
        let group = try! #require(updated.layout.firstDocumentGroup)
        let tab = try! #require(group.tab(id: tabID))

        #expect(tab.fileURL == dotVariant.standardizedFileURL)
        #expect(tab.title == "notes.md")
    }

    // MARK: - replaceDocumentTab (inline file-browser navigation)

    @Test func replacingDocumentTabKeepsSameTabAndActivePane() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, tabID) = try! #require(
            openTab("/tmp/notes.md", associatedWith: terminal.id, in: session)
        )
        let updated = try! #require(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: tabID,
                fileURL: URL(fileURLWithPath: "/tmp/other.md"),
                in: firstSession
            )
        )
        let group = try! #require(updated.layout.firstDocumentGroup)
        let tab = try! #require(group.tab(id: tabID))

        #expect(tab.fileURL == URL(fileURLWithPath: "/tmp/other.md"))
        #expect(tab.title == "other.md")
        #expect(
            tab.associatedTerminalPaneID == terminal.id,
            "browser navigation stays within the same document↔terminal pairing"
        )
        #expect(group.tabs.count == 1)
        #expect(updated.activePaneID == terminal.id)
    }

    @Test func replacingDocumentTabStoresStandardizedURL() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, tabID) = try! #require(openTab("/tmp/notes.md", in: session))
        let dotVariant = URL(fileURLWithPath: "/tmp/./other.md")
        let updated = try! #require(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: tabID,
                fileURL: dotVariant,
                in: firstSession
            )
        )
        let group = try! #require(updated.layout.firstDocumentGroup)
        let tab = try! #require(group.tab(id: tabID))

        #expect(tab.fileURL == dotVariant.standardizedFileURL)
        #expect(tab.title == "other.md")
        #expect(updated.activePaneID == terminal.id)
    }

    @Test func replacingWithAlreadyOpenFileSelectsExistingTabAndDropsNavigator() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        let (firstSession, firstID) = try! #require(openTab("/tmp/notes.md", in: session))
        let (secondSession, secondID) = try! #require(openTab("/tmp/other.md", in: firstSession))

        let updated = try! #require(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: firstID,
                fileURL: URL(fileURLWithPath: "/tmp/./other.md"),
                in: secondSession
            )
        )
        let group = try! #require(updated.layout.firstDocumentGroup)

        #expect(group.tabs.count == 1)
        #expect(group.tab(id: firstID) == nil, "the navigating tab is removed")
        #expect(group.selectedTabID == secondID, "the existing tab is selected")
        let remaining = try! #require(group.tab(id: secondID))
        #expect(remaining.fileURL == URL(fileURLWithPath: "/tmp/other.md").standardizedFileURL)
        #expect(updated.activePaneID == terminal.id)
    }

    @Test func replacingUnknownDocumentTabIsNoOp() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id

        #expect(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: DocumentPane.ID(),
                fileURL: URL(fileURLWithPath: "/tmp/other.md"),
                in: session
            ) == nil
        )
    }
}

// MARK: - Branch changes provenance

@Suite("Branch changes document tabs")
struct BranchChangesDocumentTabTests {
    private static let cacheURL = URL(fileURLWithPath: "/tmp/cache/a1b2.branch-changes.md")

    private func identity(branch: String? = "feature/x") -> BranchChangesIdentity {
        BranchChangesIdentity(
            gitBranch: branch,
            baseRef: "refs/remotes/origin/main",
            repositoryName: "awesomux"
        )!
    }

    private func session() -> (TerminalSession, TerminalPane) {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id
        return (session, terminal)
    }

    @Test func opensAssociatedWithThePassedPaneAndTitledFromTheIdentity() throws {
        let (session, terminal) = session()
        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        let group = try #require(opened.session.layout.firstDocumentGroup)
        let tab = try #require(group.tab(id: opened.newTabID))
        #expect(tab.associatedTerminalPaneID == terminal.id)
        #expect(tab.branchChangesIdentity == identity())
        // Never the hashed filename.
        #expect(tab.title == identity().documentTitle)
        #expect(tab.title.contains("feature/x"))
        #expect(!tab.isEditable)
    }

    @Test func aSecondOpenRefreshesTheSameTabInPlace() throws {
        let (session, terminal) = session()
        let first = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        let second = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(),
                in: first.session,
                now: Date()
            ))
        #expect(second.newTabID == first.newTabID)
        let group = try #require(second.session.layout.firstDocumentGroup)
        #expect(group.tabs.count == 1)
    }

    @Test func aTabThatAlreadyHasProvenanceIsNeverRetargeted() throws {
        let (session, terminal) = session()
        let first = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        // The same cache path with a different identity cannot happen — the slot
        // is keyed on the identity — but if it did, the stored provenance wins.
        let second = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(branch: "other"),
                in: first.session,
                now: Date()
            ))
        let group = try #require(second.session.layout.firstDocumentGroup)
        let tab = try #require(group.tab(id: second.newTabID))
        #expect(tab.branchChangesIdentity == identity())
    }

    /// Pinned behavior, not endorsed behavior. Two live panes on the same branch
    /// of the same checkout render into ONE cache slot, so the second pane's
    /// invocation reuses the first pane's tab, and the never-retarget-live rule
    /// keeps send/stage pointed at the first pane. The alternative — a tab per
    /// pane — needs a product decision about what a second pane's Show Branch
    /// Changes should even mean, and that is queued on the pull request. This
    /// test exists so the decision is a decision rather than a silent drift.
    @Test func twoLivePanesSharingASlotKeepTheFirstPanesAssociation() throws {
        let first = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let second = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(orientation: .vertical, first: .pane(first), second: .pane(second))
            )
        )
        session.activePaneID = first.id

        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: first.id,
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        let reopened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: second.id,
                branchChangesIdentity: identity(),
                in: opened.session,
                now: Date()
            ))
        #expect(reopened.newTabID == opened.newTabID)
        let group = try #require(reopened.session.layout.firstDocumentGroup)
        #expect(group.tabs.count == 1)
        #expect(try #require(group.tab(id: reopened.newTabID)).associatedTerminalPaneID == first.id)
    }

    @Test func aDeadPaneAssociationIsNotInvented() throws {
        let (session, _) = session()
        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: UUID(),
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        let group = try #require(opened.session.layout.firstDocumentGroup)
        // The reducer stores nil rather than silently retargeting to whichever
        // terminal happens to be active. The command's own guard is what stops
        // a tab from being opened at all once its pane is gone.
        #expect(try #require(group.tab(id: opened.newTabID)).associatedTerminalPaneID == nil)
    }

    @Test func aBranchChangesTabCannotBeNavigatedElsewhere() throws {
        let (session, terminal) = session()
        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: Self.cacheURL,
                associatedTerminalPaneID: terminal.id,
                branchChangesIdentity: identity(),
                in: session,
                now: Date()
            ))
        #expect(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: opened.newTabID,
                fileURL: URL(fileURLWithPath: "/tmp/other.md"),
                in: opened.session
            ) == nil)
    }
}
