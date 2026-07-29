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

    /// Arms the REAL dwell against a calm active pane: baseline unread 0, no
    /// pending prompt. The calm workspace goes first so `init` seeds selection to
    /// it and the write below is a genuine change that reaches the arming path.
    private func storeArmedOnCalmSelection(_ session: TerminalSession) -> SessionStore {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "One", sessions: [calm, session])],
            acknowledgementDwellNanoseconds: 20_000_000
        )
        store.needsInputSectionEnabled = true
        store.selectedSessionID = session.id
        return store
    }

    /// The dwell exists to clear attention the user has actually SEEN. A prompt
    /// that lands after the dwell armed has not been seen — and because the pane
    /// is focused, `AgentRuntimeEventReducer` deliberately adds no unread, so the
    /// baseline's unread-growth guard cannot see it either. Without the
    /// prompt-at-baseline guard the dwell auto-answers a question nobody read.
    ///
    /// The `.bell` control store is the timing witness, not a wall-clock sleep:
    /// it arms SECOND with the same dwell, so its deadline falls after the
    /// subject's, and its ack landing proves the subject's dwell has already
    /// fired. A loaded suite can therefore delay this test but never make it
    /// pass vacuously.
    @Test func aPromptArrivingMidDwellIsNotAcknowledged() async {
        let subjectSession = TerminalSession(title: "subject", workingDirectory: "~")
        let controlSession = TerminalSession(title: "control", workingDirectory: "~")
        let subject = storeArmedOnCalmSelection(subjectSession)
        let control = storeArmedOnCalmSelection(controlSession)

        // Same main-actor run as the arming above, so both land strictly inside
        // their dwell windows — no dwell task can run until we suspend.
        subject.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, attentionReason: .permissionPrompt),
            to: subjectSession.id,
            paneID: subjectSession.activePaneID,
            terminalIsFocused: true
        )
        control.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, attentionReason: .bell),
            to: controlSession.id,
            paneID: controlSession.activePaneID,
            terminalIsFocused: true
        )
        // The exact reason the unread guard is blind to a focused-pane prompt.
        #expect(subject.session(id: subjectSession.id)?.activePane?.unreadNotificationCount == 0)

        // Negative control: a `.bell` is a notice, not a question, so the dwell
        // must still acknowledge it — the guard is scoped to reasons that block
        // on a human answer, not widened to all attention.
        let controlAcknowledged = await waitUntilEventually {
            control.session(id: controlSession.id)?.activePane?.attentionReason == nil
        }
        #expect(controlAcknowledged)

        #expect(
            subject.session(id: subjectSession.id)?.activePane?.attentionReason
                == .permissionPrompt
        )
        #expect(subject.session(id: subjectSession.id)?.needsUserInput == true)
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
