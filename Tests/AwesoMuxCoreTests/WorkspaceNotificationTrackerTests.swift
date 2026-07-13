import AwesoMuxCore
import XCTest

final class WorkspaceNotificationTrackerTests: XCTestCase {
    func testEmitsEventWhenBackgroundWorkspaceUnreadCountIncreases() {
        let selectedSession = makeSession(title: "active")
        let backgroundSession = makeSession(title: "agent", state: .running)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [selectedSession, backgroundSession])
        ])

        let updatedBackgroundSession = makeSession(
            id: backgroundSession.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [selectedSession, updatedBackgroundSession])
            ],
            selectedSessionID: selectedSession.id
        )

        XCTAssertEqual(events, [
            WorkspaceNotificationEvent(
                sessionID: backgroundSession.id,
                title: "agent",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1
            )
        ])
    }

    func testDoesNotEmitForSelectedWorkspace() {
        let session = makeSession(title: "active")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "active",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: session.id
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testEmitsForBackgroundWaitingTurnCompletionUnread() {
        let selectedSession = makeSession(title: "active")
        let backgroundSession = makeSession(
            title: "agent",
            state: .waiting,
            unreadNotificationCount: 0
        )
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [selectedSession, backgroundSession])
        ])

        let updatedBackgroundSession = makeSession(
            id: backgroundSession.id,
            title: "agent",
            state: .waiting,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [selectedSession, updatedBackgroundSession])
            ],
            selectedSessionID: selectedSession.id,
            notifyOnTurnDone: true
        )

        XCTAssertEqual(events, [
            WorkspaceNotificationEvent(
                sessionID: backgroundSession.id,
                title: "agent",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1,
                kind: .turnDone
            )
        ])
    }

    func testDoesNotEmitTurnCompletionWhenToggleOff() {
        let selectedSession = makeSession(title: "active")
        let backgroundSession = makeSession(title: "agent", state: .waiting)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [selectedSession, backgroundSession])
        ])

        let updated = makeSession(
            id: backgroundSession.id,
            title: "agent",
            state: .waiting,
            unreadNotificationCount: 1
        )
        // Toggle defaults off: a background turn-end must not fire.
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [selectedSession, updated])
            ],
            selectedSessionID: selectedSession.id
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testDoesNotEmitForSelectedActiveWaitingTurnCompletionUnread() {
        let session = makeSession(title: "active", state: .waiting)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "active",
            state: .waiting,
            unreadNotificationCount: 1
        )
        // Enabled but the focused sub-option is off: the focused workspace is
        // suppressed even with turn-done delivery on.
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: session.id,
            notifyOnTurnDone: true
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testEmitsForFocusedWorkspaceWhenFocusedSubOptionOn() {
        let session = makeSession(title: "active", state: .waiting)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "active",
            state: .waiting,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: session.id,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true
        )

        XCTAssertEqual(events.map(\.kind), [.turnDone])
    }

    func testEmitsForSelectedWorkspaceWhenAppIsInactive() {
        let session = makeSession(title: "active")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "active",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: session.id,
            isAppActive: false
        )

        XCTAssertEqual(events, [
            WorkspaceNotificationEvent(
                sessionID: session.id,
                title: "active",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1
            )
        ])
    }

    func testDoesNotEmitWhenUnreadCountDoesNotIncrease() {
        let session = makeSession(
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [session])
            ],
            selectedSessionID: nil
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testDoesNotEmitWhenOutputMarksNeedsAttentionIsDisabled() {
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
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [attentionSession])
            ],
            selectedSessionID: nil,
            isAppActive: false,
            outputMarksNeedsAttention: false
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testEmitsAgainAfterNotificationsAreAcknowledged() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let firstAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        XCTAssertEqual(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [firstAttentionSession])
                ],
                selectedSessionID: nil
            ).count,
            1
        )

        let acknowledgedSession = makeSession(
            id: session.id,
            title: "agent",
            state: .running,
            unreadNotificationCount: 0
        )
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [acknowledgedSession])
                ],
                selectedSessionID: session.id
            ).isEmpty
        )

        let secondAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        XCTAssertEqual(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [secondAttentionSession])
                ],
                selectedSessionID: nil
            ).count,
            1
        )
    }

    func testEmitsDeferredInterruptiveAfterFocusLoss() {
        // The user is attending the session when it transitions to
        // .needsAttention — visibleState delivery only, no banner. When
        // they later look away, re-evaluating must surface the deferred
        // banner exactly once.
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

        // First evaluation while attending: no interruptive, baseline preserved.
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
                selectedSessionID: session.id,
                isAppActive: true
            ).isEmpty
        )

        // Focus lost: same state, but isAppActive=false now grants the
        // interruptive channel. Pending count delta vs preserved baseline
        // surfaces the banner.
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            selectedSessionID: session.id,
            isAppActive: false
        )

        XCTAssertEqual(events, [
            WorkspaceNotificationEvent(
                sessionID: session.id,
                title: "agent",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1
            )
        ])
    }

    func testDoesNotReEmitInterruptiveAfterDeliveryWhenFocusFlaps() {
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
        _ = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            selectedSessionID: session.id,
            isAppActive: true
        )
        let firstFire = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            selectedSessionID: session.id,
            isAppActive: false
        )
        XCTAssertEqual(firstFire, [
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
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
                selectedSessionID: session.id,
                isAppActive: true
            ).isEmpty
        )
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
                selectedSessionID: session.id,
                isAppActive: false
            ).isEmpty
        )
    }

    func testIndependentSessionsTransitionWithoutCrossPollination() {
        // Two background sessions in the same group both flip to
        // needsAttention with isAppActive=false. Both should emit, each
        // with its own session-specific event payload — no cross-talk in
        // the per-session baseline accounting.
        let sessionA = makeSession(title: "alpha")
        let sessionB = makeSession(title: "bravo")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [sessionA, sessionB])
        ])

        let escalatedA = makeSession(
            id: sessionA.id,
            title: "alpha",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let escalatedB = makeSession(
            id: sessionB.id,
            title: "bravo",
            state: .needsAttention,
            unreadNotificationCount: 1
        )

        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [escalatedA, escalatedB])],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.sessionID)), [sessionA.id, sessionB.id])
        XCTAssertEqual(events.first(where: { $0.sessionID == sessionA.id })?.title, "alpha")
        XCTAssertEqual(events.first(where: { $0.sessionID == sessionB.id })?.title, "bravo")
    }

    func testUpdatesBaselineAfterEmitting() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        _ = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: nil
        )

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: nil
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testPrunesBaselineForRemovedSessions() {
        let removedSession = makeSession(
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [removedSession])
        ])

        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [],
                selectedSessionID: nil,
                isAppActive: false
            ).isEmpty
        )

        let reintroducedSession = makeSession(
            id: removedSession.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [reintroducedSession])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events, [
            WorkspaceNotificationEvent(
                sessionID: removedSession.id,
                title: "agent",
                groupName: "awesoMux",
                workingDirectory: "~",
                agentKind: .claudeCode,
                unreadNotificationCount: 1
            )
        ])
    }

    func testDisplayContextPrefersWorkingDirectoryLeaf() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent",
            groupName: "Work",
            workingDirectory: "~/Development/awesomux/",
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        XCTAssertEqual(event.displayContext, "awesomux")
    }

    func testDisplayContextFallsBackToGroupForHomeDirectory() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent",
            groupName: "awesoMux",
            workingDirectory: "~",
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        XCTAssertEqual(event.displayContext, "awesoMux")
    }

    func testDisplayContextFallsBackToGroupForAbsoluteHomeDirectory() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent",
            groupName: "awesoMux",
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        XCTAssertEqual(event.displayContext, "awesoMux")
    }

    func testDisplayContextUsesParentPathWhenDirectoryLeafCollides() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let first = makeSession(
            title: "agent",
            workingDirectory: "\(home)/client-a/web"
        )
        let second = makeSession(
            title: "agent",
            workingDirectory: "\(home)/client-b/web"
        )
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [first, second])
        ])

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [
                    makeSession(
                        id: first.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: first.workingDirectory
                    ),
                    makeSession(
                        id: second.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: second.workingDirectory
                    )
                ])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events.first(where: { $0.sessionID == first.id })?.displayContext, "client-a/web")
        XCTAssertEqual(events.first(where: { $0.sessionID == second.id })?.displayContext, "client-b/web")
    }

    func testDisplayContextIncludesGroupWhenSameDirectoryExistsInDifferentGroups() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let first = makeSession(title: "agent", workingDirectory: "\(home)/web")
        let second = makeSession(title: "agent", workingDirectory: "\(home)/web")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "Work", sessions: [first]),
            SessionGroup(name: "Scratch", sessions: [second])
        ])

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "Work", sessions: [
                    makeSession(
                        id: first.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: first.workingDirectory
                    )
                ]),
                SessionGroup(name: "Scratch", sessions: [
                    makeSession(
                        id: second.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: second.workingDirectory
                    )
                ])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events.first(where: { $0.sessionID == first.id })?.displayContext, "Work · web")
        XCTAssertEqual(events.first(where: { $0.sessionID == second.id })?.displayContext, "Scratch · web")
    }

    func testDisplayContextAppendsOrdinalForExactDuplicatesInSameGroup() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let first = makeSession(title: "agent", workingDirectory: "\(home)/web")
        let second = makeSession(title: "agent", workingDirectory: "\(home)/web")
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "Work", sessions: [first, second])
        ])

        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "Work", sessions: [
                    makeSession(
                        id: first.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: first.workingDirectory
                    ),
                    makeSession(
                        id: second.id,
                        title: "agent",
                        state: .needsAttention,
                        unreadNotificationCount: 1,
                        workingDirectory: second.workingDirectory
                    )
                ])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events.first(where: { $0.sessionID == first.id })?.displayContext, "Work · web (1 of 2)")
        XCTAssertEqual(events.first(where: { $0.sessionID == second.id })?.displayContext, "Work · web (2 of 2)")
    }

    func testNotificationSubtitleShowsTitleByDefaultAndContextWhenOptedIn() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent",
            groupName: "Work",
            workingDirectory: "~/Development/awesomux",
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        // Title is baseline identity and shows even when details are off; the
        // opt-in only adds the group/path context.
        XCTAssertEqual(event.notificationSubtitle(showWorkspaceDetails: false), "agent")
        XCTAssertEqual(event.notificationSubtitle(showWorkspaceDetails: true), "agent · awesomux")
    }

    func testNotificationSubtitleSanitizesDynamicDetails() {
        let event = WorkspaceNotificationEvent(
            sessionID: TerminalSession.ID(),
            title: "agent\u{202E}",
            displayContext: "web\u{200B}",
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )

        XCTAssertEqual(event.notificationSubtitle(showWorkspaceDetails: true), "agent · web")
    }

    func testBannerIconFollowsLoudestPaneNotFirstCrossing() {
        // S2: the banner is one-per-workspace. Its icon must follow the loudest
        // pane (the sidebar rollup winner), not whichever pane happened to cross
        // its baseline first in tree order. Here pane A is already waiting while
        // pane B newly crosses — the banner should still show A's kind.
        let paneA = TerminalPane(
            title: "claude", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1,
            executionPlan: .local
        )
        let paneB = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            unreadNotificationCount: 0,
            executionPlan: .local
        )
        let initial = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB)
            )),
            activePaneID: paneA.id
        )
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "ws", sessions: [initial])
        ])

        let paneBUpdated = TerminalPane(
            id: paneB.id, title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 1,
            executionPlan: .local
        )
        let updated = TerminalSession(
            id: initial.id,
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneBUpdated)
            )),
            activePaneID: paneA.id
        )

        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "ws", sessions: [updated])],
            selectedSessionID: nil
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.agentKind, updated.agentRollup().winningAgentKind)
        XCTAssertEqual(events.first?.agentKind, .claudeCode)
    }

    func testMutedWorkspaceDoesNotEmitOnUnreadIncrease() {
        let session = makeSession(title: "agent", notificationsMuted: true)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1,
            notificationsMuted: true
        )
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [attentionSession])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testMutedWorkspaceSwallowsBannerRatherThanDeferringToUnmute() {
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
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [mutedAttentionSession])
                ],
                selectedSessionID: nil,
                isAppActive: false
            ).isEmpty
        )

        // Derive the unmuted session by value-copy + flag flip so the pane UUID
        // carries. A fresh makeSession would mint a new pane, orphaning the
        // muted-era baseline and burst-firing a banner the mute was meant to
        // swallow — the production path mutates one pane in place.
        var unmutedAttentionSession = mutedAttentionSession
        unmutedAttentionSession.notificationsMuted = false
        XCTAssertTrue(
            tracker.notificationEvents(
                afterUpdating: [
                    SessionGroup(name: "awesoMux", sessions: [unmutedAttentionSession])
                ],
                selectedSessionID: nil,
                isAppActive: false
            ).isEmpty
        )
    }

    func testUnmutedWorkspaceEmitsForNewAttentionAfterUnmute() {
        // Unmute swallows the muted-era backlog but a fresh crossing after
        // unmute is a new attention episode and must fire.
        let session = makeSession(title: "agent", notificationsMuted: true)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let mutedAttentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention,
            unreadNotificationCount: 1,
            notificationsMuted: true
        )
        _ = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [mutedAttentionSession])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        // Reuse the muted step's pane identity (value-copy + flag flip), then
        // bump its unread to 2. This exercises the real crossing: the muted-era
        // baseline carried at 1, and 1→2 after unmute is a new episode that must
        // fire. A fresh makeSession would fire too, but only because a new pane's
        // baseline starts at 0 — passing for the wrong reason.
        var escalatedAfterUnmute = mutedAttentionSession
        escalatedAfterUnmute.notificationsMuted = false
        guard case .pane(var escalatedPane) = escalatedAfterUnmute.layout else {
            return XCTFail("expected single-pane layout from makeSession")
        }
        escalatedPane.unreadNotificationCount = 2
        escalatedAfterUnmute.layout = .pane(escalatedPane)
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [escalatedAfterUnmute])
            ],
            selectedSessionID: nil,
            isAppActive: false
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionID, session.id)
    }

    func testMutedWorkspaceDoesNotEmitWaitingTurnCompletion() {
        let session = makeSession(title: "agent", state: .waiting, notificationsMuted: true)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updatedSession = makeSession(
            id: session.id,
            title: "agent",
            state: .waiting,
            unreadNotificationCount: 1,
            notificationsMuted: true
        )
        // Turn-done delivery is on; mute (not the toggle) must swallow it.
        let events = tracker.notificationEvents(
            afterUpdating: [
                SessionGroup(name: "awesoMux", sessions: [updatedSession])
            ],
            selectedSessionID: nil,
            isAppActive: false,
            notifyOnTurnDone: true
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testMutedSiblingDoesNotSuppressUnmutedWorkspace() {
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

        XCTAssertEqual(events.map(\.sessionID), [loud.id])
    }

    // MARK: - Multi-pane kind selection

    func testNeedsAttentionWinsWhenTurnDonePaneIsEarlierInTreeOrder() {
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
        let session = makeSplitSession(first: turnDone, second: needy)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updated = makeSplitSession(
            id: session.id,
            first: bumpUnread(turnDone),
            second: bumpUnread(needy)
        )
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [updated])],
            selectedSessionID: nil,
            isAppActive: false,
            notifyOnTurnDone: true
        )

        XCTAssertEqual(events.map(\.kind), [.needsAttention])
    }

    func testTurnDoneSurvivesWhenSiblingNeedsAttentionIsToggledOff() {
        // needs-attention OFF, turn-done ON. A needs-attention pane crossing
        // first must not (a) claim the banner as .needsAttention only to be
        // dropped, nor (b) starve the deliverable turn-done sibling by advancing
        // its own baseline and consuming the one-per-workspace slot.
        let needy = TerminalPane(
            title: "claude", workingDirectory: "~", agentKind: .claudeCode,
            agentExecutionState: .waiting, attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let turnDone = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .waiting, attentionReason: nil,
            executionPlan: .local
        )
        let session = makeSplitSession(first: needy, second: turnDone)
        var tracker = WorkspaceNotificationTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let updated = makeSplitSession(
            id: session.id,
            first: bumpUnread(needy),
            second: bumpUnread(turnDone)
        )
        let events = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [updated])],
            selectedSessionID: nil,
            isAppActive: false,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true
        )

        XCTAssertEqual(events.map(\.kind), [.turnDone])
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
