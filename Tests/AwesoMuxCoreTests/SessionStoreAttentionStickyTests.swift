import AwesoMuxBridgeProtocol
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

    @Test func selectingANeedyWorkspaceCapturesTheSticky() {
        let a = needy("alpha")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [a])])
        store.needsInputSectionEnabled = true
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
}
