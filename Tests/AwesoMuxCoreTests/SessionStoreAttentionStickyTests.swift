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
