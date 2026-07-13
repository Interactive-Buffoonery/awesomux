import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct PaneTitleFreezeRuleTests {
    private func session(title: String = "shell") -> TerminalSession {
        TerminalSession(title: title, workingDirectory: "~")
    }

    @Test
    func liveTitleUpdatesWhenNotFrozen() throws {
        let s = session()
        let paneID = s.activePaneID
        let updated = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        #expect(updated.layout.pane(id: paneID)?.title == "claude")
        #expect(updated.layout.pane(id: paneID)?.isTitleUserEdited == false)
    }

    @Test
    func liveTitleClearsSyntheticWorkspaceMetadata() throws {
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 1)
        let session = TerminalSession(
            title: syntheticTitle.canonicalTitle,
            workingDirectory: "~",
            syntheticTitle: syntheticTitle
        )

        let updated = try #require(PaneLayoutReducer.updatePane(
            in: session,
            paneID: session.activePaneID,
            title: "zsh",
            workingDirectory: nil,
            localHostnames: []
        ))

        #expect(updated.title == "zsh")
        #expect(updated.syntheticTitle == nil)
    }

    @Test
    func renameSetsFlagAndStoresLiveTitleForReset() throws {
        var s = session()
        let paneID = s.activePaneID
        // Live title arrives first, caching liveTerminalTitle.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == true)
    }

    @Test
    func frozenPaneIgnoresLiveTitle() throws {
        var s = session()
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // A later OSC title must NOT overwrite the custom name.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == true)
    }

    @Test
    func resetClearsFlagAndReadoptsLiveTitle() throws {
        var s = session()
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // While frozen the live title keeps being cached.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.resetPaneTitle(in: s, paneID: paneID))
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == false)
        #expect(s.layout.pane(id: paneID)?.title == "zsh")
    }

    @Test
    func renameRejectsBlankTitle() {
        let s = session()
        #expect(PaneLayoutReducer.renamePane(in: s, paneID: s.activePaneID, title: "   ") == nil)
    }

    @Test
    func resetWithNoCachedLiveTitleFallsBackToCwdBasename() throws {
        // A restored frozen pane has no liveTerminalTitle yet (runtime-only).
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        let s = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))
        let reset = try #require(PaneLayoutReducer.resetPaneTitle(in: s, paneID: pane.id))
        #expect(reset.layout.pane(id: pane.id)?.isTitleUserEdited == false)
        #expect(reset.layout.pane(id: pane.id)?.title == "awesomux")
    }

    @Test
    func renamingActivePaneInSplitDoesNotRetitleWorkspace() throws {
        // F6: in a SPLIT, the workspace title is independent of pane titles —
        // a pane's custom name is a pane nickname, never the workspace name.
        // (The lone-pane case is deliberately different; see the lone-pane
        // carve-out tests below.)
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        var s2 = try #require(PaneLayoutReducer.setActivePane(id: paneID, in: split.session))
        s2 = try #require(PaneLayoutReducer.renamePane(in: s2, paneID: paneID, title: "My Backend"))
        #expect(s2.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s2.title == "claude")
    }

    /// The headline sync behaviour in a SPLIT: once a pane is frozen, a LATER
    /// live OSC title must still flow to the WORKSPACE title (which mirrors the
    /// live terminal) while the pane's own displayed title stays pinned to the
    /// custom name. Proves the workspace tracks the terminal AND the pane stays
    /// pinned — the two halves of the F6 independence rule where it applies.
    @Test
    func frozenPaneInSplitLiveTitleUpdatesWorkspaceTitleNotPaneTitle() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        var s2 = try #require(PaneLayoutReducer.setActivePane(id: paneID, in: split.session))
        s2 = try #require(PaneLayoutReducer.renamePane(in: s2, paneID: paneID, title: "My Backend"))
        // A later OSC title on the frozen active pane.
        s2 = try #require(PaneLayoutReducer.updatePane(
            in: s2, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        // Workspace title follows the LIVE terminal title…
        #expect(s2.title == "zsh")
        // …while the pane stays pinned to the user's custom name.
        #expect(s2.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s2.layout.pane(id: paneID)?.isTitleUserEdited == true)
    }

    // MARK: - Lone-pane carve-out (agent renames must be visible)

    /// A lone pane has no pane title bar, so the workspace bar is the only
    /// surface a pinned title can show on ("a single full-window pane stays
    /// bare — the workspace bar already names it", INT-283 design). Only agent
    /// channels (local runtime rename + bridge pane-rename) reach this case —
    /// the pane-bar rename affordance needs 2+ panes — and an agent rename that
    /// produced no visible change anywhere was the INT-698 live-smoke finding
    /// this pins.
    @Test
    func renamingLoneActivePaneRetitlesWorkspace() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.title == "My Backend")
    }

    @Test
    func lonePinnedPaneWorkspaceTitleIgnoresLaterLiveTitle() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // A later OSC title keeps being cached for reset, but must not clobber
        // the pinned workspace title while the pane stays lone + pinned.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        #expect(s.title == "My Backend")
        #expect(s.layout.pane(id: paneID)?.liveTerminalTitle == "zsh")
    }

    @Test
    func resettingLonePaneReadoptsLiveWorkspaceTitle() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        #expect(s.title == "My Backend")
        s = try #require(PaneLayoutReducer.resetPaneTitle(in: s, paneID: paneID))
        #expect(s.title == "zsh")
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == false)
    }

    @Test
    func userRenamedWorkspaceStillWinsOverLonePaneRename() throws {
        var s = session(title: "My Workspace")
        s.isTitleUserEdited = true
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // The pane pin lands, but the user's explicit workspace name wins.
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.title == "My Workspace")
    }

    /// Adversarial-review coverage: closing a split down to a lone PINNED
    /// survivor is the other direction of the carve-out transition — the pin
    /// must take over the workspace title at the close, not wait for the next
    /// OSC tick.
    @Test
    func closingToLonePinnedSurvivorRetitlesWorkspace() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        var s2 = try #require(PaneLayoutReducer.setActivePane(id: paneID, in: split.session))
        s2 = try #require(PaneLayoutReducer.renamePane(in: s2, paneID: paneID, title: "My Backend"))
        // In the split, F6 keeps the live title in the workspace bar.
        #expect(s2.title == "zsh")
        let close = try #require(PaneLayoutReducer.closePane(id: split.newPaneID, in: s2))
        let survivor = try #require(close.session)
        // Lone + pinned now — the pin owns the workspace title.
        #expect(survivor.title == "My Backend")
    }

    /// Adversarial-review coverage: the carve-out only changes which cached
    /// title reaches workspace chrome — remote-host detection keeps consuming
    /// the live OSC title on a lone pinned pane.
    @Test
    func lonePinnedPaneStillDetectsRemoteHostFromLiveTitle() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // The detector fails closed on an empty local-names baseline, so give
        // it one (same shape as RemoteSessionDetectorTests).
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "ed@webserver: ~/app", workingDirectory: nil,
            localHostnames: ["mymac", "mymac.local"]
        ))
        let pane = try #require(s.layout.pane(id: paneID))
        #expect(pane.remoteHost == "webserver")
        #expect(pane.liveTerminalTitle == "ed@webserver: ~/app")
        // The workspace title stays pinned.
        #expect(s.title == "My Backend")
    }

    /// Adversarial-review coverage: a user-renamed workspace survives the whole
    /// split → close round trip with a pinned pane in play.
    @Test
    func userRenamedWorkspaceSurvivesSplitAndClose() throws {
        var s = session(title: "My Workspace")
        s.isTitleUserEdited = true
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        #expect(split.session.title == "My Workspace")
        let close = try #require(PaneLayoutReducer.closePane(id: split.newPaneID, in: split.session))
        let survivor = try #require(close.session)
        #expect(survivor.title == "My Workspace")
    }

    /// Review (Codex HIGH): splitting a renamed pane must NOT carry the custom
    /// name into the new (unfrozen) sibling, or it leaks into the workspace
    /// title when that sibling is focused. The new pane seeds from the source's
    /// LIVE title instead.
    @Test
    func splittingRenamedPaneDoesNotLeakCustomNameToNewPane() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        // Live title cached, then a user rename pins a different name.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))

        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        // The new pane (now active) seeds from the live title, not the pin, and
        // is unfrozen — so focusing it does NOT put "My Backend" in the chrome.
        let newPane = try #require(split.session.layout.pane(id: split.newPaneID))
        #expect(newPane.title == "zsh")
        #expect(newPane.isTitleUserEdited == false)
        #expect(split.session.title != "My Backend")
    }

    /// Review (Codex HIGH): recycle leaks immediately (it syncs at once), so the
    /// recycled pane must also seed from the live title, keeping the custom name
    /// out of the workspace title.
    @Test
    func recyclingRenamedPaneDoesNotLeakCustomNameToWorkspace() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))

        let recycled = try #require(
            PaneLayoutReducer.recycleActivePane(in: s, now: Date())
        )
        #expect(recycled.session.title != "My Backend")
        let recycledPane = try #require(recycled.session.activePane)
        #expect(recycledPane.title == "zsh")
        #expect(recycledPane.isTitleUserEdited == false)
    }

    /// Review (Codex HIGH, restored-frozen gap): a frozen pane with NO live-title
    /// cache (e.g. just restored from disk, before any OSC tick) must seed a
    /// split/recycle from the CWD BASENAME, never the pinned custom name — the
    /// `?? title` fallback would otherwise leak the pin into the new unfrozen
    /// pane and the workspace title.
    @Test
    func splittingRestoredFrozenPaneSeedsCwdNotCustomName() throws {
        // A restored frozen pane: custom title, user-edited, liveTerminalTitle nil.
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        let s = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))

        let split = try #require(
            PaneLayoutReducer.splitActivePane(in: s, orientation: .vertical, now: Date())
        )
        let newPane = try #require(split.session.layout.pane(id: split.newPaneID))
        #expect(newPane.title == "awesomux")          // cwd basename, NOT the pin
        #expect(newPane.title != "My Backend")
        #expect(newPane.isTitleUserEdited == false)
        #expect(split.session.title != "My Backend")
    }

    @Test
    func recyclingRestoredFrozenPaneSeedsCwdNotCustomName() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        let s = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))

        let recycled = try #require(PaneLayoutReducer.recycleActivePane(in: s, now: Date()))
        let recycledPane = try #require(recycled.session.activePane)
        #expect(recycledPane.title == "awesomux")
        #expect(recycledPane.title != "My Backend")
        #expect(recycled.session.title != "My Backend")
    }
}
