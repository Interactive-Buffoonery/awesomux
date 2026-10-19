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

}
