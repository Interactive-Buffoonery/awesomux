import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceAttentionReducer")
struct WorkspaceAttentionReducerTests {
    @MainActor @Test("mixed terminal signals coalesce, stay seen during a burst, and rearm after quiet")
    func outputBurstStaysSeen() {
        let session = TerminalSession(title: "shell", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [session])])
        let now = ProcessInfo.processInfo.systemUptime
        for index in 0..<37 {
            store.recordOutputNotification(
                sessionID: session.id, paneID: session.activePaneID,
                reason: index.isMultiple(of: 2) ? .bell : .desktopNotification,
                observedAt: now - 4 + Double(index) / 100, canNotify: true)
        }
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.attentionReason == .bell)
        store.markPaneSeen(sessionID: session.id, paneID: session.activePaneID)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: now + 0.1, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        #expect(store.session(id: session.id)?.attentionReason == nil)
        // Ghostty forwards identical OSC notices about five seconds apart, even during a continuous stream.
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: now + 5.2, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .desktopNotification, observedAt: now + 16.2, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.attentionReason == .desktopNotification)
    }

    @MainActor @Test("zero unread acknowledgement fences queued output", arguments: ["pane", "workspace", "input", "all"])
    func queuedOutputCannotOutliveAcknowledgement(action: String) {
        let session = TerminalSession(title: "shell", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [session])])
        let oldEvent = ProcessInfo.processInfo.systemUptime - 1
        switch action {
        case "pane": store.markPaneSeen(sessionID: session.id, paneID: session.activePaneID)
        case "workspace": store.markWorkspaceSeen(id: session.id)
        case "input": store.markNeedsAttentionPromptAnswered(id: session.id, paneID: session.activePaneID)
        default: store.acknowledgeAllSessions()
        }
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: oldEvent, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: oldEvent + 1.1, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: oldEvent + 20, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
    }

    @MainActor
    @Test("generic output credit survives permission masking and drain", arguments: [AttentionReason.bell, .desktopNotification])
    func outputCreditIsSeparateFromPermissions(reason: AttentionReason) {
        let session = TerminalSession(title: "shell", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [session])])
        let now = ProcessInfo.processInfo.systemUptime
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: reason, observedAt: now, canNotify: true)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: 2, hasPending: true)
        for index in 1...37 {
            store.recordOutputNotification(
                sessionID: session.id, paneID: session.activePaneID,
                reason: reason, observedAt: now + Double(index) / 100, canNotify: true)
        }
        #expect(store.session(id: session.id)?.unreadNotificationCount == 3)
        #expect(store.session(id: session.id)?.attentionReason == .permissionPrompt)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: -2, hasPending: false)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.attentionReason == reason)
    }

    @MainActor @Test("foreground output and pending permissions do not add generic credits")
    func outputDoesNotContaminatePromptCredits() {
        let session = TerminalSession(title: "shell", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [session])])
        let now = ProcessInfo.processInfo.systemUptime
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: now, canNotify: false)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .bell, observedAt: now + 1, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: 2, hasPending: true)
        store.recordOutputNotification(
            sessionID: session.id, paneID: session.activePaneID,
            reason: .desktopNotification, observedAt: now + 10, canNotify: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 2)
        store.markPaneSeen(sessionID: session.id, paneID: session.activePaneID)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: 1, hasPending: true)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: -2, hasPending: true)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.attentionReason == .permissionPrompt)
        store.updatePermissionPromptAttention(sessionID: session.id, paneID: session.activePaneID, countDelta: -1, hasPending: false)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
    }

    // A controlled scheduler is necessary to place a new event inside the old dwell window.
    @MainActor @Test(arguments: ["pane", "workspace", "dismiss"])
    func explicitSeenDoesNotClearANewerNotification(action: String) async {
        let session = TerminalSession(
            title: "agent", workingDirectory: "~", agentKind: .codex, agentState: .needsAttention, unreadNotificationCount: 2)
        let store = SessionStore(groups: [SessionGroup(name: "Project", sessions: [session])])
        let scheduler = TestScheduler()
        store.acknowledgementCoordinator.delay = { _ in
            await scheduler.wait(for: .zero)
            try Task.checkCancellation()
        }
        store.setActivePane(id: session.activePaneID, in: session.id)
        #expect(await waitUntil { scheduler.sleeperCount == 1 })
        switch action {
        case "pane": store.markPaneSeen(sessionID: session.id, paneID: session.activePaneID)
        case "workspace": store.markWorkspaceSeen(id: session.id)
        default: store.dismissAgentAttentionReminder(paneID: session.activePaneID)
        }
        store.markSessionNeedsAttention(id: session.id, paneID: session.activePaneID)
        scheduler.advance()
        await drainMainQueue()
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
    }

    @Test(arguments: [
        (AttentionReason.permissionPrompt, AttentionReason?.some(.permissionPrompt)),
        (.userInputRequired, .some(.userInputRequired)),
        (.bell, nil), (.desktopNotification, nil), (.processError, nil), (.unknown, nil),
    ])
    func inferredClear(reason: AttentionReason, expected: AttentionReason?) {
        var session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex, attentionReason: reason)
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: session.activePaneID,
            update: .init(agentExecutionState: .running, clearsAttention: true),
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(session.attentionReason == expected)
        #expect(session.needsUserInput == (expected != nil))
    }

    @Test(arguments: [
        (AttentionReason.permissionPrompt, AgentState.running, true, AttentionReason?.some(.permissionPrompt)),
        (.userInputRequired, .running, true, .some(.userInputRequired)),
        (.bell, .running, true, nil), (.processError, .running, true, nil),
        (.permissionPrompt, .needsAttention, false, .some(.permissionPrompt)),
        (.userInputRequired, .needsAttention, false, .some(.userInputRequired)),
    ])
    func legacyAttention(reason: AttentionReason, state: AgentState, clears: Bool, expected: AttentionReason?) {
        var pane = TerminalPane(title: "codex", workingDirectory: "~", agentKind: .codex, attentionReason: reason, executionPlan: .local)
        pane.applyLegacyAgentState(state, clearsAttentionForExecutionState: clears)
        #expect(pane.attentionReason == expected)
        if state == .running { #expect(pane.agentExecutionState == .running) } else { #expect(pane.agentState == .needsAttention) }
    }

    @Test("permission queue mirrors count and clears only its own reason")
    func permissionPromptAttentionLifecycle() {
        var session = TerminalSession(title: "remote", workingDirectory: "~")
        let paneID = session.activePaneID

        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: 2, hasPending: true
        )
        #expect(session.layout.pane(id: paneID)?.attentionReason == .permissionPrompt)
        #expect(session.layout.pane(id: paneID)?.unreadNotificationCount == 2)

        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: -2, hasPending: false
        )
        #expect(session.layout.pane(id: paneID)?.attentionReason == nil)
        #expect(session.layout.pane(id: paneID)?.unreadNotificationCount == 0)
        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: 0, hasPending: true
        )
        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: 0, hasPending: false
        )
        #expect(session.attentionReason == nil)
    }

    @Test(
        "a lower-priority attentionReason cannot clobber a higher-priority pending one",
        arguments: [AttentionReason.permissionPrompt, .unknown])
    func updatePaneDoesNotDowngradeHigherPriorityAttention(initialReason: AttentionReason) throws {
        var session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            attentionReason: initialReason
        )

        if initialReason == .unknown {
            _ = WorkspaceAttentionReducer.updatePane(
                &session, paneID: session.activePaneID,
                update: .init(attentionReason: .permissionPrompt), now: Date(timeIntervalSince1970: 0)
            )
            #expect(session.attentionReason == .permissionPrompt)
        }

        // A `.bell` arriving while a permission prompt is still pending must
        // not overwrite it (INT-506).
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(attentionReason: .bell),
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(session.attentionReason == .permissionPrompt)

        // A higher-priority reason still wins over an existing lower one.
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(attentionReason: .userInputRequired),
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(session.attentionReason == .userInputRequired)

        // An INFERRED clear no longer wins over a pending prompt — that was the
        // retraction that dropped the row out of Needs Input a second after it
        // lifted. Only an explicit acknowledgement takes it back.
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(clearsAttention: true),
            now: Date(timeIntervalSince1970: 3)
        )
        #expect(session.attentionReason == .userInputRequired)

        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(clearsAttention: true, attentionClearIsAuthoritative: true),
            now: Date(timeIntervalSince1970: 4)
        )
        #expect(session.attentionReason == nil)
    }

    @Test("markSessionNeedsAttention's update keeps a pending prompt lifted")
    func markSessionNeedsAttentionKeepsPendingPrompt() {
        var session = TerminalSession(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .permissionPrompt
        )

        // Exactly the update `SessionStore.markSessionNeedsAttention` builds for
        // the generic background-output path in `GhosttySurfaceTerminalEvents`.
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(agentState: .needsAttention, unreadNotificationDelta: 1),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(session.attentionReason == .permissionPrompt)
        #expect(session.needsUserInput)
        #expect(session.unreadNotificationCount == 1)
    }

    @Test("one pane's waiting clears only its own attention; a sibling stays loud")
    func updatePaneIsScopedToOnePane() throws {
        // The regression PR #149 faked with the `isSinglePane` gate: in a split,
        // clearing one pane's attention must NOT touch the sibling's.
        // `.bell` rather than `.permissionPrompt`: this test is about pane
        // SCOPING, and only a retractable (low-priority) reason clears through
        // an inferred update at all — the pending-prompt case is covered by
        // `inferredClear`.
        let needy = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .bell,
            executionPlan: .local
        )
        let sibling = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .userInputRequired,
            executionPlan: .local
        )
        var session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(needy),
                second: .pane(sibling)
            )),
            activePaneID: needy.id
        )

        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: needy.id,
            update: .init(agentExecutionState: .waiting, clearsAttention: true),
            now: Date()
        )

        #expect(session.layout.pane(id: needy.id)?.attentionReason == nil)
        #expect(session.layout.pane(id: sibling.id)?.attentionReason == .userInputRequired)
        #expect(session.needsAcknowledgement == true)
    }

    @Test("a pane process error bumps unread only on first unfocused transition")
    func paneErrorsBumpUnreadOnlyOnFirstTransition() throws {
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )

        let first = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let second = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(session.attentionReason == .processError)
        #expect(session.unreadNotificationCount == 1)
        #expect(first?.newCount == 1)
        #expect(second == nil)
    }

    @Test("recordPaneExitError does not overwrite an existing live prompt")
    func paneErrorPreservesExistingPrompt() {
        // Consistency: a pane already showing a permission prompt must keep
        // it — a late process-exit error must not silently replace the reason the
        // user still needs to act on.
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt
        )

        let change = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(session.attentionReason == .permissionPrompt)
        // Already in needs-attention, so no new unread bump either.
        #expect(change == nil)
    }

    @Test("acknowledgePane clears unread and pending attention", arguments: [3, 0])
    func acknowledgePaneClearsBoth(unread: Int) {
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt,
            unreadNotificationCount: unread
        )

        let change = WorkspaceAttentionReducer.acknowledgePane(
            &session,
            paneID: session.activePaneID
        )
        #expect(session.unreadNotificationCount == 0)
        #expect(session.attentionReason == nil)
        #expect(!session.needsUserInput)
        if unread == 0 {
            #expect(change == nil)
        } else {
            #expect(change?.oldCount == unread)
            #expect(change?.newCount == 0)
        }
    }

    @Test("acknowledgement sweeps clear every pending pane", arguments: [false, true])
    func acknowledgeAllPanesClearsEveryPaneInSession(allSessions: Bool) {
        let a = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let b = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1,
            executionPlan: .local
        )
        var session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(a),
                second: .pane(b)
            )),
            activePaneID: a.id
        )

        let change: WorkspaceAttentionReducer.UnreadChange?
        if allSessions {
            var groups = [SessionGroup(name: "main", sessions: [session])]
            WorkspaceAttentionReducer.acknowledgeAllSessions(in: &groups)
            session = groups[0].sessions[0]
            change = nil
        } else {
            change = WorkspaceAttentionReducer.acknowledgeAllPanes(in: &session)
        }

        // Legacy full dismissal clears every pane; mark-as-seen preserves explicit requests.
        #expect(session.layout.pane(id: a.id)?.attentionReason == nil)
        #expect(session.layout.pane(id: b.id)?.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.needsAcknowledgement == false)
        if !allSessions {
            #expect(change?.oldCount == 3)
            #expect(change?.newCount == 0)
        }
    }

}
