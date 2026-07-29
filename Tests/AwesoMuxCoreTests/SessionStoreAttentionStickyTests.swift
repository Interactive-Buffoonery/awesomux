import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite struct SessionStoreAttentionStickyTests {
    private func needy(_ title: String) -> TerminalSession {
        var session = TerminalSession(title: title, workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        return session
    }

    /// The calm session goes FIRST so `init` seeds the selection to it: the
    /// write below is then a genuine change that reaches the setter's
    /// `refreshAttentionSticky()`. With the needy session first, the write is a
    /// same-value no-op and the `needsInputSectionEnabled` didSet is what arms
    /// the sticky — which would leave the setter's arming path untested.
    @Test func selectingANeedyWorkspaceCapturesTheSticky() {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [calm, a])])
        store.needsInputSectionEnabled = true
        #expect(store.attentionStickySessionID == nil)
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)
    }

    @Test func selectingACalmWorkspaceReleasesTheSticky() {
        let a = needy("alpha")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a, b])])
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)
        store.selectedSessionID = b.id
        #expect(store.attentionStickySessionID == nil)
    }

    @Test func pinnedSessionsNeverBecomeSticky() {
        // A pinned workspace renders in Pinned; holding a sticky for it would
        // hijack the tile into Needs Input the moment it is unpinned.
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        store.needsInputSectionEnabled = true
        store.togglePin(sessionID: a.id)
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == nil)
    }

    @Test func deliberateAcknowledgeReleasesTheStickyButTheDwellDoesNot() {
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        store.acknowledgeSession(id: a.id, releasesAttentionSticky: false)
        #expect(store.attentionStickySessionID == a.id)
        store.acknowledgeAllPanes(in: a.id)
        #expect(store.attentionStickySessionID == nil)
    }

    @Test func clearAllNotificationsDrainsTheWholeSection() {
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        store.acknowledgeAllSessions()
        #expect(store.attentionStickySessionID == nil)
        #expect(store.liftedSessionIDs.isEmpty)
    }

    @Test func liftedSessionIDsIsEmptyWhenDisabled() {
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        #expect(store.needsInputSectionEnabled == false)
        #expect(store.liftedSessionIDs.isEmpty)
        store.needsInputSectionEnabled = true
        #expect(store.liftedSessionIDs == [a.id])
    }

    /// The off→on direction above leaves the disable path unexercised, and a
    /// stale list would keep rendering a section the setting just turned off.
    @Test func disablingTheSectionDrainsTheLiftedListAndSticky() {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [calm, a])])
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)
        #expect(store.liftedSessionIDs == [a.id])

        store.needsInputSectionEnabled = false
        #expect(store.liftedSessionIDs.isEmpty)
        #expect(store.attentionStickySessionID == nil)
    }

    @Test func liftedSessionIDsExcludesPinned() {
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        store.needsInputSectionEnabled = true
        store.togglePin(sessionID: a.id)
        #expect(store.liftedSessionIDs.isEmpty)
    }

    /// Drives the REAL 500 ms dwell rather than calling `acknowledgeSession`
    /// directly, so deleting `releasesAttentionSticky: false` from the dwell's
    /// call site fails here instead of shipping a section that evicts the row
    /// the user is reading.
    @Test func theRealDwellAcknowledgesWithoutReleasingTheSticky() async {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let a = needy("alpha")
        let store = SessionStore(
            groups: [SessionGroup(name: "One", sessions: [calm, a])],
            acknowledgementDwellNanoseconds: 10_000_000
        )
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)

        let dwellRan = await waitUntilEventually {
            store.session(id: a.id)?.needsUserInput == false
        }
        #expect(dwellRan)
        #expect(store.attentionStickySessionID == a.id)
        // Still lifted purely on the sticky's strength — the point of the whole
        // mechanism.
        #expect(store.liftedSessionIDs == [a.id])
    }

    /// The dwell can be armed without a selection change: a workspace that is
    /// already selected starts needing input, then the user clicks into its
    /// terminal (`becomeFirstResponder` → `setActivePane`). Nothing on that path
    /// touches `selectedSessionID`, so only the arming choke point itself can
    /// capture the sticky before the dwell acknowledges the row mid-answer.
    @Test func armingTheDwellCapturesTheStickyForAnAlreadySelectedWorkspace() async throws {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "One", sessions: [a])],
            acknowledgementDwellNanoseconds: 10_000_000
        )
        store.needsInputSectionEnabled = true
        #expect(store.selectedSessionID == a.id)
        #expect(store.attentionStickySessionID == nil)

        // The agent raises a permission prompt on the already-selected
        // workspace. No selection change, so no sticky is captured yet — it
        // lifts on `needsUserInput` alone.
        let paneID = try #require(store.session(id: a.id)?.activePaneID)
        store.updatePermissionPromptAttention(
            sessionID: a.id,
            paneID: paneID,
            countDelta: 1,
            hasPending: true
        )
        #expect(store.attentionStickySessionID == nil)
        #expect(store.liftedSessionIDs == [a.id])

        // The user clicks into the terminal to answer.
        store.setActivePane(id: paneID, in: a.id)

        let dwellRan = await waitUntilEventually {
            store.session(id: a.id)?.needsUserInput == false
        }
        #expect(dwellRan)
        // The dwell acknowledged, but the row must stay put while it is read.
        #expect(store.attentionStickySessionID == a.id)
        #expect(store.liftedSessionIDs == [a.id])
    }

    /// A bulk restore can reuse session IDs with different values, so a
    /// surviving sticky would lift a restored workspace that never needed input.
    @Test func replaceStateDropsTheSticky() {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [calm, a])])
        store.needsInputSectionEnabled = true
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)

        // Same session ID, restored calm — the exact ID-reuse hazard.
        let restored = TerminalSession(id: a.id, title: "alpha", workingDirectory: "~")
        store.replaceState(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "One", sessions: [restored])],
                selectedSessionID: restored.id
            )
        )
        #expect(store.attentionStickySessionID == nil)
        #expect(store.liftedSessionIDs.isEmpty)
    }
}
