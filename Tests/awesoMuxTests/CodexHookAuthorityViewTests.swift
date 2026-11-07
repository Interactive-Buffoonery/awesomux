import AppKit
@testable import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// The helper E2E does not exercise view/store integration. These cases cover
// stale hook authority hiding approval prompts when the probe is unavailable,
// and an idle composer clearing thinking while the shell is still busy.
@MainActor
@Suite("Codex hook authority at the view boundary", .serialized)
struct CodexHookAuthorityViewTests {
    @Test("Codex active controls are independent of a scrolled historical viewport")
    func activeControlsAreIndependentOfHistory() {
        let fixture = makeFixture(shellActivity: .idle)
        let composer = "› Ask Codex to do anything\nGPT-6.1-Sol low · ~\n← for agents · ? for shortcuts"
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        ageActivity(in: fixture)
        fixture.view.applyVisibleAgentSample(
            nil, agentText: questionText, now: 100.5, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.view.terminalEventState.lastAccessibilityReportedVisibleText == questionText)
        fixture.view.applyVisibleAgentSample(
            composer, agentText: nil, now: 101, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        fixture.view.applyVisibleAgentSample(
            composer, agentText: questionText, now: 102, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.view.terminalEventState.codexQuestion?.incarnation == incarnation)
        #expect(fixture.view.terminalEventState.lastAccessibilityReportedVisibleText == composer)
        #expect(fixture.store.selectedSession?.activePane?.lastAgentStateChangeAt == .distantPast)
        fixture.view.applyVisibleAgentSample(
            composer, agentText: composer, now: 103, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        #expect(fixture.view.terminalEventState.lastAccessibilityReportedVisibleText == composer)

        let fresh = makeFixture(shellActivity: .idle)
        fresh.view.applyVisibleAgentSample(
            questionText, agentText: composer, now: 100, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fresh.store.selectedSession?.attentionReason == nil)
        fresh.view.applyVisibleAgentSample(
            nil, agentText: questionText, now: 101, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fresh.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fresh.view.terminalEventState.lastAccessibilityReportedVisibleText == questionText)
    }

    @Test("a stable question returns after an accepted permission episode resolves", arguments: [false, true])
    func questionSurvivesRuntimePermissionHandoff(approvalShapedNotes: Bool) {
        let questionText =
            approvalShapedNotes
            ? "Question 1/1 (1 unanswered)\nWould you like to run the following command?\n› 1. Yes, proceed\n2. No, and tell Codex what to do differently\n3. None of the above\n\n› 1. Yes, proceed\n\ntab or esc to clear notes | enter to submit answer"
            : self.questionText
        let fixture = makeFixture(shellActivity: .idle)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 1)
        let state = fixture.view.terminalEventState
        fixture.view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, phase: .toolStart, eventID: "handoff", timestamp: Date(timeIntervalSince1970: 1)))
        fixture.view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex, attentionReason: .permissionPrompt, phase: .notification,
                eventID: "handoff", timestamp: Date(timeIntervalSince1970: 2)))
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: (state.lastRuntimeEventAppliedAt ?? 100) + 3,
            liveAgentKind: .codex, foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        fixture.view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, phase: .toolEnd, eventID: "handoff", timestamp: Date(timeIntervalSince1970: 3)))
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        let now = (state.lastRuntimeEventAppliedAt ?? 100) + 3
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: now, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 0)
        #expect(state.lastAcceptedAttentionCue == nil)
    }

    @Test("bridge attention handoffs restore a cached remote question", arguments: [false, true])
    func bridgeQuestionSurvivesAttentionHandoff(permissionQueue: Bool) throws {
        let remote = try #require(RemoteTarget(user: "test", host: "example.com"))
        let fixture = makeFixture(shellActivity: .idle, executionPlan: .ssh(SSHExecution(target: remote)))
        let state = fixture.view.terminalEventState
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: nil)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(state.codexQuestion?.incarnation == nil)
        if permissionQueue {
            GhosttyRuntime.updateBridgePermissionPromptAttention(
                sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id,
                countDelta: 1, hasPending: true, surfaceView: fixture.view)
        } else {
            for event in [
                AgentRuntimeEvent(source: .codex, phase: .toolStart, eventID: "bridge", timestamp: Date(timeIntervalSince1970: 1)),
                AgentRuntimeEvent(
                    source: .codex, attentionReason: .permissionPrompt, phase: .notification,
                    eventID: "bridge", timestamp: Date(timeIntervalSince1970: 2)),
            ] {
                GhosttyRuntime.applyBridgeAgentStatus(
                    event, sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id,
                    surfaceView: fixture.view)
            }
        }
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 103, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: nil)
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        let end = AgentRuntimeEvent(source: .codex, phase: .toolEnd, eventID: "bridge", timestamp: Date(timeIntervalSince1970: 3))
        if permissionQueue {
            GhosttyRuntime.updateBridgePermissionPromptAttention(
                sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id,
                countDelta: -1, hasPending: false, surfaceView: fixture.view)
        } else {
            GhosttyRuntime.applyBridgeAgentStatus(
                end, sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id, surfaceView: fixture.view)
        }
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        let unread = fixture.store.selectedSession?.unreadNotificationCount
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 106, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: nil)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == unread)
        #expect(state.verifiedWaitingForegroundIncarnation == nil)
        #expect(state.codexHooksDelivered == nil)
        #expect(state.lastRuntimeEventAppliedAt == nil)
        fixture.store.acknowledgeAllSessions()
        if !permissionQueue {
            GhosttyRuntime.applyBridgeAgentStatus(
                end, sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id, surfaceView: fixture.view)
        } else {
            GhosttyRuntime.updateBridgePermissionPromptAttention(
                sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id,
                countDelta: 0, hasPending: false, surfaceView: fixture.view)
        }
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 107, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: nil)
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        #expect(state.lastDetectedAgentKind == .codex)
        let otherStore = SessionStore(
            groups: [SessionGroup(name: "other", sessions: [fixture.session])], selectedSessionID: fixture.session.id)
        GhosttyRuntime.updateBridgePermissionPromptAttention(
            sessionStore: otherStore, sessionID: fixture.session.id, paneID: fixture.pane.id,
            countDelta: 1, hasPending: true, surfaceView: fixture.view)
        #expect(otherStore.selectedSession?.attentionReason == .permissionPrompt)
        #expect(state.lastDetectedAgentKind == .codex)
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        let detachedStore = SessionStore(
            groups: [SessionGroup(name: "detached", sessions: [fixture.session])], selectedSessionID: fixture.session.id)
        GhosttyRuntime.applyBridgeAgentStatus(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt, phase: .notification, eventID: "detached"),
            sessionStore: detachedStore, sessionID: fixture.session.id, paneID: fixture.pane.id, surfaceView: nil)
        #expect(detachedStore.selectedSession?.attentionReason == .permissionPrompt)
    }

    @Test("session end retires a question before an identical replacement frame", arguments: [false, true], [false, true])
    func replacementQuestionStartsNewEpisode(bridge: Bool, dismissed: Bool) throws {
        let remote = try #require(RemoteTarget(user: "test", host: "example.com"))
        let fixture = makeFixture(shellActivity: .idle, executionPlan: bridge ? .ssh(SSHExecution(target: remote)) : .local)
        let state = fixture.view.terminalEventState
        let generation = bridge ? nil : incarnation
        func apply(_ event: AgentRuntimeEvent) {
            if bridge {
                GhosttyRuntime.applyBridgeAgentStatus(
                    event, sessionStore: fixture.store, sessionID: fixture.session.id, paneID: fixture.pane.id, surfaceView: fixture.view)
            } else {
                fixture.view.applyAgentRuntimeEvent(event)
            }
        }
        apply(AgentRuntimeEvent(source: .codex, phase: .sessionStart, providerSessionID: "A", timestamp: Date(timeIntervalSince1970: 1)))
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: (state.lastRuntimeEventAppliedAt ?? 100) + 3, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: generation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 1)
        if dismissed { fixture.store.acknowledgeAllSessions() }
        apply(AgentRuntimeEvent(source: .codex, phase: .sessionEnd, providerSessionID: "A", timestamp: Date(timeIntervalSince1970: 2)))
        #expect(fixture.store.selectedSession?.agentKind == .shell)
        #expect(state.codexQuestion == nil)
        #expect(state.lastDetectedAgentKind == nil)
        apply(AgentRuntimeEvent(source: .codex, phase: .sessionStart, providerSessionID: "B", timestamp: Date(timeIntervalSince1970: 3)))
        #expect(fixture.store.selectedSession?.agentKind == .codex)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: (state.lastRuntimeEventAppliedAt ?? 100) + 3, liveAgentKind: .codex,
            foregroundCommand: "codex", foregroundIncarnation: generation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 1)
    }

    @Test("legacy input does not reparse an unchanged acknowledged frame")
    func legacyInputDoesNotRearmCachedFrame() {
        let fixture = makeFixture(shellActivity: .idle)
        let approval = "Would you like to run the following command?\n› 1. Yes, proceed\n2. No, and tell Codex what to do differently"
        fixture.view.applyVisibleAgentSample(
            approval, agentText: approval, now: 100, liveAgentKind: .codex, foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.agentState == .needsAttention)
        fixture.view.markNeedsAttentionPromptAnswered()
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        fixture.view.applyVisibleAgentSample(
            approval, agentText: approval, now: 103, liveAgentKind: .codex, foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == nil)
    }

    @Test("blocked unchanged samples do not refresh activity but remain eligible for detection")
    func blockedSampleDoesNotInventActivity() {
        let fixture = makeFixture(shellActivity: .idle)
        let state = fixture.view.terminalEventState
        state.hasObservedAgentActivity = true
        ageActivity(in: fixture)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex, foregroundCommand: nil, foregroundIncarnation: nil)
        #expect(fixture.store.selectedSession?.activePane?.lastAgentStateChangeAt != .distantPast)
        for now in [111.0, 122.0] {
            // Make the existing coarsening interval eligible without a real-time wait or a production clock seam.
            ageActivity(in: fixture)
            fixture.view.applyVisibleAgentSample(
                questionText, agentText: questionText, now: now, liveAgentKind: .codex, foregroundCommand: nil, foregroundIncarnation: nil)
            #expect(fixture.store.selectedSession?.activePane?.lastAgentStateChangeAt == .distantPast)
            #expect(state.lastDetectedVisibleText.isEmpty)
        }
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 133, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
    }

    @Test("raw text can return to an evaluated frame after a blocked observation")
    func rawReversionIsObserved() {
        let fixture = makeFixture(shellActivity: .idle)
        fixture.view.terminalEventState.hasObservedAgentActivity = true
        let composer = "› Ask Codex to do anything\nGPT-6.1-Sol low · ~\n← for agents · ? for shortcuts"
        fixture.view.applyVisibleAgentSample(
            composer, agentText: composer, now: 100, liveAgentKind: .codex, foregroundCommand: "codex", foregroundIncarnation: incarnation)
        fixture.view.applyVisibleAgentSample(
            "Loading", agentText: "Loading", now: 101, liveAgentKind: .codex, foregroundCommand: nil, foregroundIncarnation: nil)
        #expect(fixture.view.terminalEventState.lastAccessibilityReportedVisibleText == "Loading")
        ageActivity(in: fixture)
        fixture.view.applyVisibleAgentSample(
            composer, agentText: composer, now: 102, liveAgentKind: .codex, foregroundCommand: "codex", foregroundIncarnation: incarnation)
        #expect(fixture.view.terminalEventState.lastAccessibilityReportedVisibleText == composer)
        #expect(fixture.store.selectedSession?.activePane?.lastAgentStateChangeAt != .distantPast)
    }

    @Test("explicit dismissal does not rearm an unchanged question")
    func explicitDismissalRetainsItsBoundary() {
        let fixture = makeFixture(shellActivity: .idle)
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        fixture.store.acknowledgeAllSessions()
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 103, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 0)
        fixture.view.markNeedsAttentionPromptAnswered()
        fixture.view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt, phase: .notification, eventID: "after-dismissal"))
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
    }

    @Test("a removed pane cannot redirect samples or input acknowledgment to its sibling")
    func removedPaneDoesNotTouchSibling() {
        let fixture = makeFixture(shellActivity: .idle)
        let sibling = TerminalPane(
            title: "sibling", workingDirectory: "/tmp", agentKind: .shell,
            attentionReason: .permissionPrompt, unreadNotificationCount: 1, executionPlan: .local)
        fixture.store._groups[0].sessions[0].layout = .pane(sibling)
        fixture.store._groups[0].sessions[0].activePaneID = sibling.id
        ageActivity(in: fixture)
        fixture.view.terminalEventState.hasObservedAgentActivity = true
        fixture.view.applyVisibleAgentSample(
            questionText, agentText: questionText, now: 100, liveAgentKind: .codex, foregroundCommand: "codex",
            foregroundIncarnation: incarnation)
        fixture.view.applyDetectedAgentOutput(AgentOutputDetection(state: .needsAttention, codexUI: .question))
        fixture.view.markNeedsAttentionPromptAnswered()
        #expect(fixture.store.selectedSession?.activePane?.agentKind == .shell)
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        #expect(fixture.store.selectedSession?.unreadNotificationCount == 1)
        #expect(fixture.store.selectedSession?.activePane?.lastAgentStateChangeAt == .distantPast)
    }

    private func ageActivity(in fixture: Fixture) {
        fixture.store._groups[0].sessions[0].layout = fixture.store._groups[0].sessions[0].layout.mappingPanes { pane in
            var pane = pane
            pane.lastAgentStateChangeAt = .distantPast
            return pane
        }
    }

    private var questionText: String {
        "Question 1/1 (1 unanswered)\nDoes this highlight the correct agent?\n› 1. Yes\n2. No\ntab to add notes | enter to submit answer | esc to interrupt"
    }

    @Test("question editing cannot answer an existing permission request")
    func questionEditingPreservesPermission() {
        let fixture = makeFixture(shellActivity: .idle)
        _ = fixture.store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt, phase: .notification),
            to: fixture.session.id, paneID: fixture.pane.id, terminalIsFocused: true)
        fixture.view.updateCodexQuestion(
            AgentOutputDetection(state: .needsAttention, codexUI: .question), foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
        fixture.view.markNeedsAttentionPromptAnswered()
        #expect(fixture.store.selectedSession?.attentionReason == .permissionPrompt)
    }

    @Test("a static viewport skipped during the hook window is evaluated after expiry")
    func staticQuestionRetriesAfterHookWindow() {
        let state = GhosttySurfaceTerminalEventState()
        state.lastRuntimeEventAppliedAt = 100
        #expect(!state.consumeVisibleTextForDetection("question", now: 101, liveAgentKind: .codex))
        #expect(state.lastDetectedVisibleText.isEmpty)
        #expect(state.consumeVisibleTextForDetection("question", now: 103, liveAgentKind: .codex))
        #expect(!state.consumeVisibleTextForDetection("question", now: 104, liveAgentKind: .codex))
        #expect(state.hasUnevaluatedVisibleText("question", liveAgentKind: .codex, foregroundIncarnation: incarnation))
        #expect(state.consumeVisibleTextForDetection("question", now: 104, liveAgentKind: .codex, foregroundIncarnation: incarnation))
        #expect(!state.consumeVisibleTextForDetection("question", now: 105, liveAgentKind: .codex, foregroundIncarnation: incarnation))
        let kindState = GhosttySurfaceTerminalEventState()
        #expect(kindState.consumeVisibleTextForDetection("question", now: 100, liveAgentKind: .shell))
        #expect(kindState.consumeVisibleTextForDetection("question", now: 101, liveAgentKind: .codex))
    }

    @Test("question input and unknown UI do not answer a question")
    func questionNotesNavigationIsNotAnAnswer() {
        let fixture = makeFixture(shellActivity: .idle)
        let question = AgentOutputDetection(state: .needsAttention, codexUI: .question)
        fixture.view.applyDetectedAgentOutput(question)
        fixture.view.updateCodexQuestion(question, foregroundIncarnation: incarnation)
        fixture.view.markNeedsAttentionPromptAnswered()
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        fixture.view.updateCodexQuestion(nil, foregroundIncarnation: incarnation)
        fixture.view.markNeedsAttentionPromptAnswered()
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
    }

    @Test("same-process normal UI resolves only the observed question")
    func questionResponseReleasesAttention() throws {
        let fixture = makeFixture(shellActivity: .idle)
        let question = AgentOutputDetection(state: .needsAttention, codexUI: .question)
        fixture.view.applyDetectedAgentOutput(question)
        fixture.view.updateCodexQuestion(question, foregroundIncarnation: incarnation)
        let composer = try #require(
            AgentOutputDetector().detectedOutput(
                in: "› Ask Codex to do anything\nGPT-6.1-Sol low · ~\n← for agents · ? for shortcuts    ⚠ 2 warnings · f2 to view",
                liveAgentKind: .codex))
        let state = fixture.view.terminalEventState
        if state.consumeVisibleTextForDetection("composer", now: 100, liveAgentKind: .codex, foregroundIncarnation: nil) {
            fixture.view.updateCodexQuestion(composer, foregroundIncarnation: nil)
        }
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(state.hasUnevaluatedVisibleText("composer", liveAgentKind: .codex, foregroundIncarnation: incarnation))
        if state.consumeVisibleTextForDetection("composer", now: 101, liveAgentKind: .codex, foregroundIncarnation: incarnation) {
            fixture.view.updateCodexQuestion(composer, foregroundIncarnation: incarnation)
        }
        #expect(fixture.store.selectedSession?.attentionReason == nil)
        #expect(fixture.store.selectedSession?.agentExecutionState == .thinking)

        fixture.view.applyDetectedAgentOutput(question)
        fixture.view.updateCodexQuestion(question, foregroundIncarnation: incarnation)
        fixture.view.updateCodexQuestion(question, foregroundIncarnation: nil)
        fixture.view.updateCodexQuestion(composer, foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == nil)

        fixture.view.applyDetectedAgentOutput(question)
        if state.consumeVisibleTextForDetection("question", now: 102, liveAgentKind: .codex, foregroundIncarnation: nil) {
            fixture.view.updateCodexQuestion(question, foregroundIncarnation: nil)
        }
        #expect(state.hasUnevaluatedVisibleText("question", liveAgentKind: .codex, foregroundIncarnation: incarnation))
        if state.consumeVisibleTextForDetection("question", now: 103, liveAgentKind: .codex, foregroundIncarnation: incarnation) {
            fixture.view.updateCodexQuestion(question, foregroundIncarnation: incarnation)
        }
        fixture.view.updateCodexQuestion(composer, foregroundIncarnation: incarnation)
        #expect(fixture.store.selectedSession?.attentionReason == nil)

        fixture.view.applyDetectedAgentOutput(question)
        fixture.view.updateCodexQuestion(question, foregroundIncarnation: incarnation)
        fixture.view.updateCodexQuestion(composer, foregroundIncarnation: AgentForegroundIncarnation(pid: 124, startedAt: 457))
        #expect(fixture.store.selectedSession?.attentionReason == .userInputRequired)
        #expect(fixture.view.terminalEventState.codexQuestion == nil)
    }

    private var incarnation: AgentForegroundIncarnation { AgentForegroundIncarnation(pid: 123, startedAt: 456) }

    @Test("an unreadable foreground sample keeps approval detection available")
    func unreadableForegroundKeepsApprovalDetection() throws {
        let fixture = makeFixture(shellActivity: .idle)
        fixture.view.terminalEventState.codexHooksDelivered = (
            PaneStoreWriteKey(sessionID: fixture.session.id, paneID: fixture.pane.id),
            AgentForegroundIncarnation(pid: 123, startedAt: 456)
        )

        #expect(fixture.view.documentNudgeForegroundGeneration() == nil)
        #expect(!fixture.view.liveAgentHooksDelivered(for: .codex))
        fixture.view.applyDetectedAgentState(.needsAttention)

        let updated = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(updated.agentState == .needsAttention)
    }

    @Test("hookless waiting clears thinking only with a quiet shell", arguments: [ShellActivity.idle, .busy])
    func hooklessWaitingRespectsShellActivity(shellActivity: ShellActivity) throws {
        let fixture = makeFixture(shellActivity: shellActivity)
        #expect(!fixture.view.liveAgentHooksDelivered(for: .codex))

        fixture.view.applyDetectedAgentState(.waiting)

        let updated = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(updated.agentState == (shellActivity == .busy ? .thinking : .waiting))
    }

    private func makeFixture(shellActivity: ShellActivity, executionPlan: PaneExecutionPlan = .local) -> Fixture {
        let pane = TerminalPane(
            title: "Codex", workingDirectory: "/tmp", agentKind: .codex,
            agentState: .thinking, shellActivity: shellActivity, executionPlan: executionPlan
        )
        let session = TerminalSession(
            title: "Codex", workingDirectory: "/tmp", layout: .pane(pane), activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])], selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store, session: session, pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        return Fixture(pane: pane, session: session, store: store, runtime: runtime, view: view)
    }

    private struct Fixture {
        let pane: TerminalPane
        let session: TerminalSession
        let store: SessionStore
        let runtime: GhosttyRuntime
        let view: GhosttySurfaceNSView
    }
}
