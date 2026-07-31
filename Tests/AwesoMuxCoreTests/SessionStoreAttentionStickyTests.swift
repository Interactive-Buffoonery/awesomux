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
    ///
    /// Post INT-819 the dwell declines to acknowledge a blocking prompt at all,
    /// so the row survives for two independent reasons — the prompt is still
    /// live AND the sticky is held. Both are asserted: a regression that
    /// re-enabled passive clearing would still be caught by the sticky check.
    @Test func theRealDwellAcknowledgesWithoutReleasingTheSticky() async {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let a = needy("alpha")
        // A second workspace carrying only a bell. Its acknowledgement is the
        // observable proof that the real dwell fired — a blocking prompt now
        // produces no state change of its own, so there is nothing to poll on
        // the workspace under test.
        var bell = TerminalSession(title: "bell", workingDirectory: "~")
        bell.layout = bell.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .bell
            pane.unreadNotificationCount = 1
            return pane
        }
        let store = SessionStore(
            groups: [SessionGroup(name: "One", sessions: [calm, a, bell])],
            acknowledgementDwellNanoseconds: 10_000_000
        )
        store.needsInputSectionEnabled = true

        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)

        // Select the bell workspace and wait for ITS dwell to land. The dwell
        // scheduled for `a` had already elapsed by then.
        store.selectedSessionID = bell.id
        let dwellRan = await waitUntilEventually {
            store.session(id: bell.id)?.activePane?.attentionReason == nil
        }
        #expect(dwellRan, "the dwell must still clear a non-blocking reason")

        #expect(
            store.session(id: a.id)?.needsUserInput == true,
            "the dwell must not passively answer a blocking prompt"
        )

        // Re-select `a` and let its dwell run again: the prompt survives and the
        // sticky holds the row in place while it is read.
        store.selectedSessionID = a.id
        #expect(store.attentionStickySessionID == a.id)
        #expect(store.liftedSessionIDs == [a.id])

        // The sticky is what holds the row once the prompt IS answered — the
        // point of the whole mechanism. Acknowledge without releasing it, the
        // way the dwell would for a non-blocking reason.
        store.acknowledgeSession(id: a.id, releasesAttentionSticky: false)
        #expect(store.session(id: a.id)?.needsUserInput == false)
        #expect(store.attentionStickySessionID == a.id)
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

        // The user clicks into the terminal to answer. This arms the dwell
        // without a selection change — the case only the arming choke point
        // covers.
        store.setActivePane(id: paneID, in: a.id)

        // Arming is synchronous, so the sticky is captured immediately; the
        // dwell itself then declines to clear the blocking prompt (INT-819).
        #expect(store.attentionStickySessionID == a.id)
        // The prompt must SURVIVE the dwell, so there is no state change to
        // poll for. Assert the condition holds continuously across a window the
        // 10 ms dwell lands well inside: a regression that cleared it would flip
        // this to false and fail.
        let promptSurvivedTheDwell = await waitUntilEventually(deadline: .milliseconds(300)) {
            store.session(id: a.id)?.needsUserInput != true
        }
        #expect(
            !promptSurvivedTheDwell,
            "the dwell must not passively answer a blocking prompt"
        )
        // The row must stay put while it is read.
        #expect(store.attentionStickySessionID == a.id)
        #expect(store.liftedSessionIDs == [a.id])
    }

    /// Arms acknowledgement against a calm active pane: baseline unread 0, no
    /// pending prompt. The calm workspace goes first so `init` seeds selection to
    /// it and the write below is a genuine change that reaches the arming path.
    private func storeArmedOnCalmSelection(_ session: TerminalSession) -> SessionStore {
        let calm = TerminalSession(title: "calm", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "One", sessions: [calm, session])],
            acknowledgementDwellNanoseconds: 0
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
    /// The `.bell` control store is the scheduler witness: its ack landing proves
    /// the subject's acknowledgement task has also had a chance to run.
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
