import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceNotificationTrackerTests {
    @Test(arguments: [
        (
            false, true, AgentState.running, AgentState.needsAttention, 0, 1, false, false, true, false,
            [WorkspaceNotificationEvent.Kind.needsAttention]
        ),
        (true, true, .idle, .needsAttention, 0, 1, false, false, true, false, []),
        (false, true, .waiting, .waiting, 0, 1, true, false, true, false, [.turnDone]),
        (false, true, .waiting, .waiting, 0, 1, false, false, true, false, []),
        (true, true, .waiting, .waiting, 0, 1, true, false, true, false, []),
        (true, true, .waiting, .waiting, 0, 1, true, true, true, false, [.turnDone]),
        (true, false, .idle, .needsAttention, 0, 1, false, false, true, false, [.needsAttention]),
        (false, true, .needsAttention, .needsAttention, 1, 0, false, false, true, false, []),
        (false, false, .idle, .needsAttention, 0, 1, false, false, false, false, []),
        (false, false, .idle, .needsAttention, 0, 1, false, false, true, true, []),
        (false, false, .waiting, .waiting, 0, 1, true, false, true, true, []),
    ])
    func notificationGating(
        selected: Bool, active: Bool, initialState: AgentState, state: AgentState, initialUnread: Int, delta: Int,
        turnDone: Bool, focusedTurnDone: Bool, outputAttention: Bool, muted: Bool,
        expected: [WorkspaceNotificationEvent.Kind]
    ) {
        let paneID = TerminalPane.ID()
        let session = makeSession(
            title: "agent", state: initialState,
            unreadNotificationCount: initialUnread, notificationsMuted: muted, paneID: paneID)
        var tracker = WorkspaceNotificationTracker(groups: [SessionGroup(name: "awesoMux", sessions: [session])])
        let updated = makeSession(
            id: session.id, title: "agent", state: state,
            unreadNotificationCount: initialUnread + delta, notificationsMuted: muted, paneID: paneID)
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [updated])],
            selectedSessionID: selected ? session.id : nil, isAppActive: active,
            outputMarksNeedsAttention: outputAttention, notifyOnTurnDone: turnDone,
            turnDoneAlertsWhenFocused: focusedTurnDone
        )
        #expect(events.map(\.kind) == expected)
        if let kind = expected.first {
            #expect(
                events == [
                    WorkspaceNotificationEvent(
                        sessionID: session.id, title: "agent", groupName: "awesoMux",
                        workingDirectory: "~", agentKind: .claudeCode, unreadNotificationCount: initialUnread + delta, kind: kind)
                ])
        }
    }

    @Test(arguments: [
        (["Work"], ["~/Development/awesomux/"], ["awesomux"]),
        (["awesoMux"], ["~"], ["awesoMux"]),
        (["awesoMux"], [FileManager.default.homeDirectoryForCurrentUser.path], ["awesoMux"]),
        (["Work", "Work"], ["~/client-a/web", "~/client-b/web"], ["client-a/web", "client-b/web"]),
        (["Work", "Scratch"], ["~/web", "~/web"], ["Work · web", "Scratch · web"]),
        (["Work", "Work"], ["~/web", "~/web"], ["Work · web (1 of 2)", "Work · web (2 of 2)"]),
    ])
    func displayContexts(groupNames: [String], paths: [String], expected: [String]) {
        let sessions = paths.map { makeSession(title: "agent", workingDirectory: $0) }
        var groups: [SessionGroup] = []
        for (index, name) in groupNames.enumerated() {
            if let existing = groups.firstIndex(where: { $0.name == name }) {
                groups[existing].sessions.append(sessions[index])
            } else {
                groups.append(SessionGroup(name: name, sessions: [sessions[index]]))
            }
        }
        let contexts = WorkspaceNotificationEvent.displayContextsBySessionID(in: groups)
        #expect(sessions.map { contexts[$0.id] } == expected.map(Optional.some))
    }

    @Test(arguments: [false, true])
    func testEmitsAgainAfterNotificationsAreAcknowledged(removed: Bool) {
        let paneID = TerminalPane.ID()
        let session = makeSession(title: "agent", paneID: paneID)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let firstAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1, paneID: paneID
        )
        #expect(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [firstAttentionSession])
                ],
                selectedSessionID: nil
            ).count == 1)

        let acknowledgedSession = makeSession(
            id: session.id,
            title: "agent",
            state: .running,
            unreadNotificationCount: 0, paneID: paneID
        )
        #expect(
            tracker.notificationEvents(
                afterUpdating: removed
                    ? []
                    : [
                    SessionGroup(name: "awesoMux", sessions: [acknowledgedSession])
                ],
                selectedSessionID: session.id
            ).isEmpty)

        let secondAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1, paneID: paneID
        )
        let groups = [SessionGroup(name: "awesoMux", sessions: [secondAttentionSession])]
        let events = tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil)
        #expect(events.map(\.kind) == [.needsAttention])
        #expect(events.map(\.sessionID) == [session.id])
        #expect(tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil).isEmpty)
    }

    @Test func testDoesNotReEmitInterruptiveAfterDeliveryWhenFocusFlaps() {
        // Once the deferred banner has fired, repeated focus toggles should
        // not spam additional notifications for the same attention episode.
        let session = makeSession(title: "agent")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )

        // Fire the initial deferred banner via attended → unattended.
        #expect(
            tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            selectedSessionID: session.id,
            isAppActive: true
            ).isEmpty)
        let firstFire = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            selectedSessionID: session.id,
            isAppActive: false
        )
        #expect(
            firstFire == [
            WorkspaceNotificationEvent(
                sessionID: session.id,
                title: "agent",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1
            )
        ])

        // User comes back, looks away again — same count, baseline now
        // matches current. No new event.
        #expect(
            tracker.notificationEvents(
                afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
                selectedSessionID: session.id,
                isAppActive: true
            ).isEmpty)
        #expect(
            tracker.notificationEvents(
                afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
                selectedSessionID: session.id,
                isAppActive: false
            ).isEmpty)
    }

    @Test func testNotificationSubtitleSanitizesDynamicDetails() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent\u{202E}",
            displayContext: "web\u{200B}",
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        #expect(event.notificationSubtitle(showWorkspaceDetails: true) == "agent · web")
    }

    @Test(arguments: [false, true])
    func testMutedWorkspaceSwallowsBannerRatherThanDeferringToUnmute(newAttention: Bool) {
        // Mute advances the baseline, so unmuting later must not burst-fire a
        // banner for attention that arrived while muted (INT-598). Pin the pane
        // id: the baseline is per-pane, so the same pane must persist across the
        // mute → unmute passes for the baseline to carry over.
        let paneID = TerminalPane.ID()
        let session = makeSession(title: "agent", notificationsMuted: true, paneID: paneID)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        // The muted step mints its own fresh pane — harmless here, because the
        // muted branch swallows unconditionally and overwrites the baseline for
        // whatever pane it sees. The unmute step below reuses THIS pane's
        // identity, since the per-pane baseline the tracker carries is keyed by
        // pane ID, not session ID (which makeSession preserves but the pane UUID
        // does not).
        let mutedAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1,
            notificationsMuted: true,
            paneID: paneID
        )
        #expect(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [mutedAttentionSession])
                ],
                selectedSessionID: nil,
                isAppActive: false
            ).isEmpty)

        // Derive the unmuted session by value-copy + flag flip so the pane UUID
        // carries. A fresh makeSession would mint a new pane, orphaning the
        // muted-era baseline and burst-firing a banner the mute was meant to
        // swallow — the production path mutates one pane in place.
        var unmutedAttentionSession = mutedAttentionSession
        unmutedAttentionSession.notificationsMuted = false
        if newAttention {
            guard case .pane(var pane) = unmutedAttentionSession.layout else {
                Issue.record("expected single-pane layout from makeSession"); return
            }
            pane.unreadNotificationCount = 2
            unmutedAttentionSession.layout = .pane(pane)
        }
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [unmutedAttentionSession])],
            selectedSessionID: nil,
            isAppActive: false
        )
        #expect(events.count == (newAttention ? 1 : 0))
        if newAttention { #expect(events.first?.sessionID == session.id) }
    }

    @Test func testMutedSiblingDoesNotSuppressUnmutedWorkspace() {
        let muted = makeSession(title: "muted", notificationsMuted: true)
        let loud = makeSession(title: "loud")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [muted, loud])
        ])

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(
                    name: "awesoMux",
                    sessions: [
                        makeSession(
                            id: muted.id,
                            title: "muted",
                            state: .needsAttention,
                            unreadNotificationCount: 1,
                            notificationsMuted: true
                        ),
                        makeSession(
                            id: loud.id,
                            title: "loud",
                            state: .needsAttention,
                            unreadNotificationCount: 1
                        ),
                    ])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        #expect(events.map(\.sessionID) == [loud.id])
    }

    @Test(arguments: [false, true])
    func testNeedsAttentionWinsWhenTurnDonePaneIsEarlierInTreeOrder(needsAttentionEnabled: Bool) {
        // A turn-done pane earlier in tree order than a needs-attention pane must
        // still yield a .needsAttention banner — "louder wins" cannot depend on
        // which pane the loop reaches first.
        let turnDone = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .waiting, attentionReason: nil,
            executionPlan: .local
        )
        let needy = TerminalPane(
            title: "claude", workingDirectory: "~", agentKind: .claudeCode,
            agentExecutionState: .waiting, attentionReason: .permissionPrompt,
            executionPlan: .local,
        )
        let first = needsAttentionEnabled ? turnDone : needy
        let second = needsAttentionEnabled ? needy : turnDone
        let session = makeSplitSession(first: first, second: second)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let updated = makeSplitSession(id: session.id, first: bumpUnread(first), second: bumpUnread(second))
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [updated])],
            selectedSessionID: nil,
            isAppActive: false,
            notifyOnNeedsAttention: needsAttentionEnabled,
            notifyOnTurnDone: true
        )
        #expect(events.map(\.kind) == (needsAttentionEnabled ? [.needsAttention] : [.turnDone]))
    }

    private func bumpUnread(_ pane: TerminalPane) -> TerminalPane {
        TerminalPane(
            id: pane.id,
            title: pane.title,
            workingDirectory: pane.workingDirectory,
            agentKind: pane.agentKind,
            agentExecutionState: pane.agentExecutionState,
            attentionReason: pane.attentionReason,
            unreadNotificationCount: pane.unreadNotificationCount + 1,
            executionPlan: .local
        )
    }

    private func makeSplitSession(
        id: TerminalSession.ID = TerminalSession.ID(),
        first: TerminalPane,
        second: TerminalPane
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            ))
        )
    }

    private func makeSession(
        id: TerminalSession.ID = TerminalSession.ID(),
        title: String,
        state: AgentState = .idle,
        unreadNotificationCount: Int = 0,
        workingDirectory: String = "~",
        notificationsMuted: Bool = false,
        paneID: TerminalPane.ID? = nil
    ) -> TerminalSession {
        // Per-pane baselines key off pane.id. A test that mutates the SAME pane
        // across successive tracker passes (e.g. mute → unmute) must pin the
        // pane id, or each makeSession call mints a fresh random pane and the
        // baseline never carries over. Default stays fresh for the common case.
        let layout: TerminalPaneLayout? = paneID.map { paneID in
            .pane(TerminalPane(
                id: paneID,
                title: title,
                workingDirectory: workingDirectory,
                agentKind: .claudeCode,
                agentState: state,
                    unreadNotificationCount: unreadNotificationCount,
                    executionPlan: .local
            ))
        }
        return TerminalSession(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            notificationsMuted: notificationsMuted,
            agentKind: .claudeCode,
            agentState: state,
            unreadNotificationCount: unreadNotificationCount,
            layout: layout
        )
    }
}
