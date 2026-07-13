import Testing
import XCTest
@testable import AwesoMuxCore

@MainActor
final class SessionStoreTests: XCTestCase {
    func testInitSelectsFirstSession() {
        let store = SessionStore(groups: SessionStore.previewGroups)

        XCTAssertEqual(store.selectedSession?.title, "app shell")
    }

    func testDefaultInitStartsEmpty() {
        let store = SessionStore()

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
    }

    func testAcknowledgeAllPanesClearsSelectedWorkspaceOnly() {
        // M1 (INT-504 review): ⌘⇧K "Acknowledge Workspace" must clear EVERY pane
        // in the targeted workspace (not just the active one), while leaving other
        // workspaces' attention intact — that all-workspaces sweep is the separate
        // "Clear All Notifications" command.
        let paneA = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let paneB = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1,
            executionPlan: .local
        )
        let workspace1 = TerminalSession(
            title: "w1",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB)
            )),
            activePaneID: paneA.id
        )
        let otherPane = TerminalPane(
            title: "c", workingDirectory: "~", agentKind: .codex,
            attentionReason: .userInputRequired, unreadNotificationCount: 5,
            executionPlan: .local
        )
        let workspace2 = TerminalSession(
            title: "w2",
            workingDirectory: "~",
            layout: .pane(otherPane),
            activePaneID: otherPane.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [workspace1, workspace2])
        ])

        store.acknowledgeAllPanes(in: workspace1.id)

        XCTAssertFalse(store.session(id: workspace1.id)!.needsAcknowledgement)
        XCTAssertEqual(store.session(id: workspace1.id)!.unreadNotificationCount, 0)
        // The sibling workspace keeps its attention + unread.
        XCTAssertTrue(store.session(id: workspace2.id)!.needsAcknowledgement)
        XCTAssertEqual(store.session(id: workspace2.id)!.unreadNotificationCount, 5)
        XCTAssertEqual(store.unreadNotificationTotal, 5)
    }

    func testRestoreSelectsPersistedSessionAndNormalizesRuntimeState() {
        let firstPane = TerminalPane(
            title: "first pane",
            workingDirectory: "~/first",
            executionPlan: .local
        )
        let secondPane = TerminalPane(
            title: "second pane",
            workingDirectory: "~/second",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(firstPane),
                second: .pane(secondPane)
            )
        )
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~/first",
            agentKind: .shell,
            agentState: .running,
            unreadNotificationCount: 2
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~/second",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 4,
            layout: layout,
            activePaneID: secondPane.id
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "main", sessions: [firstSession, secondSession])
            ],
            selectedSessionID: secondSession.id
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSessionID, secondSession.id)
        XCTAssertEqual(store.selectedSession?.title, "second")
        XCTAssertEqual(store.selectedSession?.workingDirectory, "~/second")
        XCTAssertEqual(store.groups[0].sessions.map(\.agentState), [.idle, .idle])
        XCTAssertEqual(store.unreadNotificationTotal, 0)
        XCTAssertEqual(store.selectedSession?.activePaneID, secondPane.id)
        XCTAssertEqual(store.selectedSession?.activePane?.workingDirectory, "~/second")
    }

    func testRestoreSanitizesTitlesAndWorkingDirectories() throws {
        let restoredDirectory = try makeTemporaryHomeDirectory()
        let restoredRelativePath = "~/\(restoredDirectory.lastPathComponent)/ProjectCase"
        let restoredAbsolutePath = restoredDirectory
            .appendingPathComponent("ProjectCase", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: restoredAbsolutePath,
            withIntermediateDirectories: true
        )
        let firstPane = TerminalPane(
            title: "  first\u{202E}\n  ",
            workingDirectory: restoredRelativePath,
            executionPlan: .local
        )
        let secondPane = TerminalPane(
            title: "second",
            workingDirectory: restoredAbsolutePath,
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(firstPane),
                second: .pane(secondPane)
            )
        )
        let session = TerminalSession(
            title: "  hacked\u{202E}\n  ",
            workingDirectory: "/tmp/remote-controlled",
            agentKind: .shell,
            agentState: .running,
            layout: layout,
            activePaneID: firstPane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSession?.title, "hacked")
        XCTAssertEqual(store.selectedSession?.layout.pane(id: firstPane.id)?.title, "first")
        XCTAssertEqual(store.selectedSession?.workingDirectory, restoredRelativePath)
        XCTAssertEqual(store.selectedSession?.layout.pane(id: firstPane.id)?.workingDirectory, restoredRelativePath)
        XCTAssertEqual(
            store.selectedSession?.layout.pane(id: secondPane.id)?.workingDirectory,
            restoredAbsolutePath
        )
    }

    func testRestoreFallsBackToFirstPaneWhenActivePaneIDIsMissing() {
        let firstPane = TerminalPane(
            title: "first",
            workingDirectory: "~/first",
            executionPlan: .local
        )
        let secondPane = TerminalPane(
            title: "second",
            workingDirectory: "~/second",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(firstPane),
                second: .pane(secondPane)
            )
        )
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/tmp/remote-controlled",
            agentKind: .shell,
            agentState: .running,
            layout: layout,
            activePaneID: UUID()
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSession?.activePaneID, firstPane.id)
        XCTAssertEqual(store.selectedSession?.workingDirectory, "~/first")
    }

    func testRestorePreservesEmptySnapshot() {
        let snapshot = SessionSnapshot(groups: [], selectedSessionID: nil)

        let store = SessionStore(restoring: snapshot)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
    }

    func testRestoreSelectionFallbackSkipsEmptyLeadingGroups() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "empty", sessions: []),
                SessionGroup(name: "main", sessions: [session])
            ],
            selectedSessionID: nil
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testRestoreFallsBackWhenTitleSanitizesToEmpty() {
        let session = TerminalSession(
            title: "\u{202E}\n",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSession?.title, "shell 1")
        XCTAssertEqual(store.selectedSession?.activePane?.title, "shell 1")
    }

    func testRestoreDeduplicatesUntrustedIDs() {
        let sharedSessionID = UUID()
        let sharedPaneID = UUID()
        let sharedSplitID = UUID()
        let firstPane = TerminalPane(
            id: sharedPaneID,
            title: "first",
            workingDirectory: "~",
            executionPlan: .local
        )
        let secondPane = TerminalPane(
            id: sharedPaneID,
            title: "second",
            workingDirectory: "~",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                id: sharedSplitID,
                orientation: .vertical,
                first: .pane(firstPane),
                second: .split(
                    TerminalSplit(
                        id: sharedSplitID,
                        orientation: .horizontal,
                        first: .pane(secondPane),
                        second: .pane(TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local))
                    )
                )
            )
        )
        let firstSession = TerminalSession(
            id: sharedSessionID,
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running,
            layout: layout,
            activePaneID: firstPane.id
        )
        let secondSession = TerminalSession(
            id: sharedSessionID,
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [firstSession, secondSession])],
            selectedSessionID: firstSession.id
        )

        let store = SessionStore(restoring: snapshot)
        let sessions = store.groups.flatMap(\.sessions)
        let paneIDs = sessions.flatMap(\.layout.paneIDs)
        let restoredSplitIDs = sessions.flatMap { session in
            splitIDs(in: session.layout)
        }

        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
        XCTAssertEqual(Set(paneIDs).count, paneIDs.count)
        XCTAssertEqual(Set(restoredSplitIDs).count, restoredSplitIDs.count)
    }

    func testRestoreFallsBackToFirstSessionWhenSelectionIsMissing() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "main", sessions: [session])
            ],
            selectedSessionID: UUID()
        )

        let store = SessionStore(restoring: snapshot)

        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testSnapshotCapturesGroupsAndSelection() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "/tmp",
            agentKind: .codex,
            agentState: .idle
        )
        let groups = [
            SessionGroup(name: "main", sessions: [firstSession, secondSession])
        ]
        let store = SessionStore(
            groups: groups,
            selectedSessionID: secondSession.id
        )

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.groups, groups)
        XCTAssertEqual(snapshot.selectedSessionID, secondSession.id)
    }

    func testSnapshotRoundTripsEmptyGroups() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let emptyGroup = SessionGroup(name: "scratch", sessions: [])
        let populatedGroup = SessionGroup(name: "main", sessions: [session])
        let store = SessionStore(
            groups: [emptyGroup, populatedGroup],
            selectedSessionID: session.id
        )

        let restoredStore = SessionStore(restoring: store.snapshot())

        XCTAssertEqual(restoredStore.groups.map(\.id), [emptyGroup.id, populatedGroup.id])
        XCTAssertEqual(restoredStore.groups[0].sessions, [])
        XCTAssertEqual(restoredStore.groups[1].sessions.map(\.id), [session.id])
        XCTAssertEqual(restoredStore.selectedSessionID, session.id)
    }

    func testSelectFirstSessionIfNeededDoesNotReplaceExistingSelection() {
        let store = SessionStore(groups: SessionStore.previewGroups)
        let expectedID = SessionStore.previewGroups[1].sessions[0].id
        store.selectedSessionID = expectedID

        store.selectFirstSessionIfNeeded()

        XCTAssertEqual(store.selectedSessionID, expectedID)
    }

    func testSelectFirstSessionIfNeededSkipsEmptyLeadingGroups() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "empty", sessions: []),
            SessionGroup(name: "main", sessions: [session])
        ])
        store.selectedSessionID = nil

        store.selectFirstSessionIfNeeded()

        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testTitleSanitizerPreservesJoinedEmoji() {
        XCTAssertEqual(SessionStore.sanitizedTitle("👩‍💻"), "👩‍💻")
    }

    func testUserEditedWorkspaceTitleSurvivesPaneTitleUpdates() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let paneID = store.selectedSession!.activePaneID

        store.renameSession(id: session.id, title: "my workspace")
        store.updatePane(sessionID: session.id, paneID: paneID, title: "vim")

        XCTAssertEqual(store.selectedSession?.title, "my workspace")
        XCTAssertEqual(store.selectedSession?.activePane?.title, "vim")
    }

    func testUpdatePaneAppliesReportedCwdInDirectoryUserDoesNotOwn() {
        // INT-576: a reported live cwd in a root-owned system dir (/usr/share)
        // must be applied, not silently dropped. The validator's owner check used
        // to reject it, so the write-back never landed and the pane (and path bar)
        // stayed frozen at the persisted cwd, with the poll re-querying every ~4s.
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let paneID = store.selectedSession!.activePaneID

        store.updatePane(sessionID: session.id, paneID: paneID, workingDirectory: "/usr/share")

        XCTAssertEqual(store.selectedSession?.activePane?.workingDirectory, "/usr/share")
    }

    func testUnreadNotificationTotalSumsAcrossSessions() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )
        let thirdSession = TerminalSession(
            title: "third",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession]),
            SessionGroup(name: "scratch", sessions: [secondSession, thirdSession])
        ])

        XCTAssertEqual(store.unreadNotificationTotal, 5)
    }

    func testClearStaleErrorClearsErrorState() {
        let errored = TerminalSession(
            title: "failed shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .error
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [errored])
        ])

        XCTAssertTrue(store.clearStaleErrorIfPresent(id: errored.id))
        XCTAssertEqual(store.selectedSession?.agentState, .idle)
    }

    func testClearStaleErrorFiresWhenAttentionMasksErrorExecution() {
        // The whole point of the execution/display split: the stale-error
        // clear must read the durable execution truth, not the display
        // projection. A session that IS `.error` in execution must still
        // clear even with a lingering attentionReason alongside it —
        // otherwise a stale attention flag could hide a real error from the
        // cleanup path. (Since INT-506, `.error`/`.done` execution shows
        // through the display projection regardless of attentionReason — see
        // `AgentDisplayState.init(executionState:attentionReason:)` — so this
        // no longer masks to `.needsAttention`, but the durable-state
        // contract this test guards is unchanged.)
        let masked = TerminalSession(
            title: "errored but flagged",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .error,
            attentionReason: .bell
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [masked])
        ])
        XCTAssertEqual(store.selectedSession?.agentExecutionState, .error)

        XCTAssertTrue(store.clearStaleErrorIfPresent(id: masked.id))
        XCTAssertEqual(store.selectedSession?.agentExecutionState, .idle)
        // Attention is user-owned; clearing a stale error must not silently
        // dismiss it.
        XCTAssertEqual(store.selectedSession?.attentionReason, .bell)
    }

    func testClearStaleErrorIsNoOpForNonErrorStates() {
        let attentive = TerminalSession(
            title: "attentive",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [attentive])
        ])

        XCTAssertFalse(store.clearStaleErrorIfPresent(id: attentive.id))
        XCTAssertEqual(store.selectedSession?.agentState, .needsAttention)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 2)
    }

    func testClearStaleErrorIsNoOpForUnknownSessionID() {
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [])
        ])

        XCTAssertFalse(store.clearStaleErrorIfPresent(id: TerminalSession.ID()))
    }

    func testAcknowledgeSessionClearsAttentionStateAndBadgeCount() {
        let session = TerminalSession(
            title: "needs review",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [session])
        ])

        store.acknowledgeSession(id: session.id)

        XCTAssertEqual(store.selectedSession?.agentState, .running)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 0)
    }

    func testAcknowledgeSessionDoesNotMutateExecutionStateOrTimestamp() {
        let stateChangedAt = Date(timeIntervalSinceReferenceDate: 1_234)
        let session = TerminalSession(
            title: "needs review",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .bell,
            lastAgentStateChangeAt: stateChangedAt
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [session])
        ])

        store.acknowledgeSession(id: session.id)

        XCTAssertNil(store.selectedSession?.attentionReason)
        XCTAssertEqual(store.selectedSession?.agentExecutionState, .thinking)
        XCTAssertEqual(store.selectedSession?.lastAgentStateChangeAt, stateChangedAt)
    }

    func testSelectingSessionAcknowledgesNotificationsAfterDwell() async throws {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession])
        ], acknowledgementDwellNanoseconds: 10_000_000)

        store.selectedSessionID = secondSession.id

        XCTAssertEqual(store.selectedSession?.agentState, .needsAttention)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 2)

        let didAcknowledgeSelection = await eventually {
            store.selectedSession?.agentState == .running
                && store.selectedSession?.unreadNotificationCount == 0
        }

        XCTAssertTrue(didAcknowledgeSelection)
        XCTAssertEqual(store.selectedSession?.agentState, .running)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 0)
    }

    func testCyclingPastSessionDoesNotAcknowledgeNotifications() async throws {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let thirdSession = TerminalSession(
            title: "third",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession, thirdSession])
        ], acknowledgementDwellNanoseconds: 30_000_000)

        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, secondSession.id)

        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, thirdSession.id)

        try await Task.sleep(nanoseconds: 60_000_000)

        let skippedSession = store.groups[0].sessions[1]
        XCTAssertEqual(skippedSession.agentState, .needsAttention)
        XCTAssertEqual(skippedSession.unreadNotificationCount, 2)
    }

    func testNewNotificationDuringDwellPreservesNewState() async throws {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 1
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession])
        ], acknowledgementDwellNanoseconds: 250_000_000)

        store.selectedSessionID = secondSession.id

        // New notification arrives during the dwell window.
        try await Task.sleep(nanoseconds: 25_000_000)
        store.markSessionNeedsAttention(id: secondSession.id, unreadNotificationDelta: 1)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.selectedSession?.agentState, .needsAttention)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 2)
    }

    func testExplicitAckCancelsPendingDwell() async throws {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession])
        ], acknowledgementDwellNanoseconds: 30_000_000)

        store.selectedSessionID = secondSession.id
        store.acknowledgeSession(id: secondSession.id)

        // A new notification arrives before the original dwell would have fired.
        store.markSessionNeedsAttention(id: secondSession.id, unreadNotificationDelta: 1)

        try await Task.sleep(nanoseconds: 60_000_000)

        // The original dwell must have been cancelled — the new notification
        // is preserved, not wiped by a stale timer.
        XCTAssertEqual(store.selectedSession?.agentState, .needsAttention)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 1)
    }

    func testSwitchingActivePaneRearmsDwellToAckNewPane() async throws {
        // S3: switching the active pane within the selected workspace must
        // re-arm the selection dwell so the NEW active pane gets read-then-acked.
        // Without the reschedule the pending dwell (baselined on the old pane)
        // bails and the new active pane stays loud forever.
        let paneA = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .codex,
            attentionReason: .userInputRequired, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB)
            )),
            activePaneID: paneA.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ], acknowledgementDwellNanoseconds: 10_000_000)

        store.selectedSessionID = session.id

        // First dwell acks the active pane A (nothing to clear); B stays loud.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason,
            .userInputRequired
        )

        // Switch active pane to B → the dwell must re-arm and ack B.
        store.setActivePane(id: paneB.id, in: session.id)
        let didAcknowledgePaneB = await eventually {
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason == nil
                && store.session(id: session.id)?.layout.pane(id: paneB.id)?.unreadNotificationCount == 0
        }
        XCTAssertTrue(didAcknowledgePaneB)
        XCTAssertNil(store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason)
        XCTAssertEqual(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.unreadNotificationCount,
            0
        )
    }

    func testAcknowledgeAllSessionsClearsAttentionStateAndBadgeCounts() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession])
        ])

        store.acknowledgeAllSessions()

        XCTAssertEqual(store.unreadNotificationTotal, 0)
        XCTAssertEqual(store.groups[0].sessions.map(\.agentState), [.idle, .running])
    }

    func testAddSessionAppendsToGroupAndSelectsNewSession() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "awesoMux",
                sessions: [
                    TerminalSession(
                        title: "existing shell",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        let newSessionID = store.addSession(
            title: "new agent",
            workingDirectory: "/tmp",
            agentKind: .codex
        )

        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, newSessionID)
        XCTAssertEqual(store.selectedSession?.title, "new agent")
        XCTAssertEqual(store.selectedSession?.workingDirectory, "/tmp")
        XCTAssertEqual(store.selectedSession?.agentKind, .codex)
        XCTAssertEqual(store.selectedSession?.agentState, .running)
    }

    func testAddSessionGeneratesShellTitle() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "awesoMux",
                sessions: [
                    TerminalSession(
                        title: "shell 1",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        store.addSession()

        XCTAssertEqual(store.selectedSession?.title, "shell 2")
    }

    func testAddSessionAvoidsDuplicateGeneratedTitle() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "awesoMux",
                sessions: [
                    TerminalSession(
                        title: "shell 1",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    ),
                    TerminalSession(
                        title: "shell 3",
                        workingDirectory: "~",
                        agentKind: .shell,
                        agentState: .idle
                    )
                ]
            )
        ])

        store.addSession()

        XCTAssertEqual(store.selectedSession?.title, "shell 4")
    }

    func testAddSessionInheritsSelectedWorkingDirectory() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "/Users/example/Development/awesomux",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession])
        ])

        store.addSession()

        XCTAssertEqual(
            store.selectedSession?.workingDirectory,
            "/Users/example/Development/awesomux"
        )
    }

    func testSplitActivePaneCreatesVerticalLayoutAndSelectsNewPane() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "/Users/example/Development/awesomux",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let newPaneID = store.splitActivePane(orientation: .vertical)

        XCTAssertEqual(store.selectedSession?.activePaneID, newPaneID)

        guard case let .split(split) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(split.orientation, .vertical)
        XCTAssertEqual(split.firstFraction, 0.5)
        XCTAssertEqual(split.first.firstPane?.workingDirectory, "/Users/example/Development/awesomux")
        XCTAssertEqual(split.second.firstPane?.id, newPaneID)
    }

    func testResizeSplitUpdatesFraction() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)

        guard case let .split(split) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        store.resizeSplit(id: split.id, firstFraction: 0.7)

        guard case let .split(resizedSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(resizedSplit.id, split.id)
        XCTAssertEqual(resizedSplit.firstFraction, 0.7)
    }

    func testResizeSplitClampsFraction() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)

        guard case let .split(split) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        store.resizeSplit(id: split.id, firstFraction: 0.01)

        guard case let .split(resizedSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(resizedSplit.firstFraction, 0.15)

        store.resizeSplit(id: split.id, firstFraction: 0.99)

        guard case let .split(upperClampedSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(upperClampedSplit.firstFraction, 0.85)
    }

    func testResizeSplitNormalizesNonFiniteFraction() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)

        guard case let .split(split) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        store.resizeSplit(id: split.id, firstFraction: .nan)

        guard case let .split(resizedSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertTrue(resizedSplit.firstFraction.isFinite)
        XCTAssertEqual(resizedSplit.firstFraction, 0.5)
    }

    func testResizeNestedSplitPreservesOuterFraction() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)
        _ = store.splitActivePane(orientation: .horizontal)

        guard case let .split(rootSplit) = store.selectedSession?.layout,
              case let .split(nestedSplit) = rootSplit.second else {
            return XCTFail("Expected nested split layout")
        }

        store.resizeSplit(id: rootSplit.id, firstFraction: 0.65)
        store.resizeSplit(id: nestedSplit.id, firstFraction: 0.7)

        guard case let .split(resizedRootSplit) = store.selectedSession?.layout,
              case let .split(resizedNestedSplit) = resizedRootSplit.second else {
            return XCTFail("Expected nested split layout")
        }

        XCTAssertEqual(resizedRootSplit.firstFraction, 0.65)
        XCTAssertEqual(resizedNestedSplit.firstFraction, 0.7)
    }

    func testResizeActiveSplitGrowsContainingPane() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!

        store.resizeActiveSplit(by: 0.05)

        guard case let .split(grownSecondPaneSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(store.selectedSession?.activePaneID, secondPaneID)
        XCTAssertEqual(grownSecondPaneSplit.firstFraction, 0.45)

        store.setActivePane(id: firstPaneID, in: session.id)
        store.resizeActiveSplit(by: 0.05)

        guard case let .split(grownFirstPaneSplit) = store.selectedSession?.layout else {
            return XCTFail("Expected split layout")
        }

        XCTAssertEqual(grownFirstPaneSplit.firstFraction, 0.5)
    }

    func testSplitActivePaneCreatesHorizontalNestedLayout() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let firstSplitPaneID = store.splitActivePane(orientation: .vertical)
        let secondSplitPaneID = store.splitActivePane(orientation: .horizontal)

        XCTAssertNotNil(firstSplitPaneID)
        XCTAssertEqual(store.selectedSession?.activePaneID, secondSplitPaneID)

        guard case let .split(rootSplit) = store.selectedSession?.layout,
              case let .split(nestedSplit) = rootSplit.second else {
            return XCTFail("Expected nested split layout")
        }

        XCTAssertEqual(rootSplit.orientation, .vertical)
        XCTAssertEqual(nestedSplit.orientation, .horizontal)
    }

    func testSetActivePaneIgnoresUnknownPane() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let originalPaneID = store.selectedSession?.activePaneID

        store.setActivePane(id: UUID(), in: session.id)

        XCTAssertEqual(store.selectedSession?.activePaneID, originalPaneID)
    }

    func testFocusNextPaneWrapsAcrossPaneOrder() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!
        let thirdPaneID = store.splitActivePane(orientation: .horizontal)!

        store.focusPane(.next)

        XCTAssertEqual(store.selectedSession?.activePaneID, firstPaneID)

        store.focusPane(.next)

        XCTAssertEqual(store.selectedSession?.activePaneID, secondPaneID)

        store.focusPane(.next)

        XCTAssertEqual(store.selectedSession?.activePaneID, thirdPaneID)
    }

    func testUserEditedWorkspaceTitleSurvivesPaneFocusChanges() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)

        store.renameSession(id: session.id, title: "my workspace")
        store.focusPane(.next)

        XCTAssertEqual(store.selectedSession?.title, "my workspace")
    }

    func testFocusPreviousPaneWrapsAcrossPaneOrder() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!
        let thirdPaneID = store.splitActivePane(orientation: .horizontal)!

        store.setActivePane(id: firstPaneID, in: session.id)
        store.focusPane(.previous)

        XCTAssertEqual(store.selectedSession?.activePaneID, thirdPaneID)

        store.focusPane(.previous)

        XCTAssertEqual(store.selectedSession?.activePaneID, secondPaneID)
    }

    func testFocusPaneRepairsMissingActivePane() {
        var session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        session.activePaneID = UUID()
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        store.focusPane(.next)

        XCTAssertEqual(store.selectedSession?.activePaneID, store.selectedSession?.layout.firstPaneID)
    }

    func testCloseActivePaneCollapsesSplitAndSelectsSiblingPane() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let originalPaneID = store.selectedSession!.activePaneID
        let newPaneID = store.splitActivePane(orientation: .vertical)

        let closedPaneID = store.closeActivePane()

        XCTAssertEqual(closedPaneID, newPaneID)
        XCTAssertEqual(store.selectedSession?.activePaneID, originalPaneID)

        guard case let .pane(pane) = store.selectedSession?.layout else {
            return XCTFail("Expected split to collapse to a pane")
        }

        XCTAssertEqual(pane.id, originalPaneID)
    }

    func testCloseActivePaneCollapsesNestedSplit() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        _ = store.splitActivePane(orientation: .vertical)
        let nestedSurvivorID = store.selectedSession!.activePaneID
        let nestedClosedID = store.splitActivePane(orientation: .horizontal)

        let closedPaneID = store.closeActivePane()

        XCTAssertEqual(closedPaneID, nestedClosedID)
        XCTAssertEqual(store.selectedSession?.activePaneID, nestedSurvivorID)

        guard case let .split(rootSplit) = store.selectedSession?.layout,
              case let .pane(nestedSurvivorPane) = rootSplit.second else {
            return XCTFail("Expected nested split to collapse to its sibling pane")
        }

        XCTAssertEqual(rootSplit.orientation, .vertical)
        XCTAssertEqual(nestedSurvivorPane.id, nestedSurvivorID)
    }

    func testCloseActivePaneIgnoresSinglePaneSession() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        XCTAssertNil(store.closeActivePane())
        XCTAssertEqual(store.selectedSession?.layout.paneIDs, [session.activePaneID])
    }

    func testRecycleActivePaneKeepsSinglePaneSessionOpen() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let recycledPaneID = store.recycleActivePane()

        XCTAssertEqual(recycledPaneID, session.activePaneID)
        XCTAssertEqual(store.groups[0].sessions.map(\.id), [session.id])
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.selectedSession?.layout.paneIDs.count, 1)
        XCTAssertNotEqual(store.selectedSession?.activePaneID, session.activePaneID)
        XCTAssertEqual(store.selectedSession?.activePane?.title, "first")
        XCTAssertEqual(store.selectedSession?.activePane?.workingDirectory, "~")
        XCTAssertEqual(store.selectedSession?.agentState, .idle)
        XCTAssertEqual(store.selectedSession?.unreadNotificationCount, 0)
    }

    func testRecycleActivePanePreservesUserEditedWorkspaceTitle() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            isTitleUserEdited: true,
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        store.updatePane(sessionID: session.id, paneID: session.activePaneID, title: "vim")

        store.recycleActivePane()

        XCTAssertEqual(store.selectedSession?.title, "first")
        XCTAssertEqual(store.selectedSession?.activePane?.title, "vim")
    }

    func testRecycleActivePaneClearsFinishedAgentState() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .done
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        store.recycleActivePane()

        XCTAssertEqual(store.selectedSession?.agentState, .idle)
    }

    func testRecycleActivePaneInSplitSessionReplacesOnlyActivePane() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!
        store.setActivePane(id: firstPaneID, in: session.id)

        let replacedPaneID = store.recycleActivePane()

        XCTAssertEqual(replacedPaneID, firstPaneID)
        let remainingIDs = store.selectedSession?.layout.paneIDs ?? []
        XCTAssertEqual(remainingIDs.count, 2)
        XCTAssertTrue(remainingIDs.contains(secondPaneID))
        XCTAssertFalse(remainingIDs.contains(firstPaneID))
    }

    func testRecycleActivePaneReturnsNilForUnknownSession() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        XCTAssertNil(store.recycleActivePane(in: UUID()))
        XCTAssertEqual(store.selectedSession?.activePaneID, session.activePaneID)
    }

    func testSplitActivePaneStartsNewPaneIdle() {
        // S1 (INT-504 review): splitting a `.done` pane resets that pane's stale
        // finished state so the workspace rollup follows the fresh idle shell
        // rather than staying "Done" — `.done` outranks `.idle`. The new active
        // pane is the fresh idle shell.
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .done
        )
        let priorPaneID = session.activePaneID
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let newPaneID = store.splitActivePane(orientation: .vertical)
        XCTAssertNotNil(newPaneID)
        XCTAssertEqual(store.selectedSession?.activePane?.agentExecutionState, .idle)
        XCTAssertEqual(
            store.selectedSession?.layout.pane(id: priorPaneID)?.agentExecutionState,
            .idle
        )
    }

    func testSessionLookupByIDReflectsLiveLayoutAfterMutation() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!

        store.setActivePane(id: firstPaneID, in: session.id)
        _ = store.closePane(id: secondPaneID, in: session.id)

        XCTAssertEqual(store.session(id: session.id)?.layout.paneCount, 1)
        XCTAssertTrue(store.session(id: session.id)?.layout.isSinglePane ?? false)
    }

    func testClosePaneClosesTargetPaneWithoutChangingActiveSibling() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!

        store.setActivePane(id: firstPaneID, in: session.id)
        let closeResult = store.closePane(id: secondPaneID, in: session.id)

        XCTAssertEqual(closeResult, .pane(secondPaneID))
        XCTAssertEqual(store.selectedSession?.activePaneID, firstPaneID)

        guard case let .pane(remainingPane) = store.selectedSession?.layout else {
            return XCTFail("Expected split to collapse to the remaining pane")
        }

        XCTAssertEqual(remainingPane.id, firstPaneID)
    }

    func testClosePaneClosesSessionWhenLastPaneExits() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "/tmp/awesomux-close-pane",
            agentKind: .shell,
            agentState: .running
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession, secondSession])
        ])
        store.selectedSessionID = firstSession.id

        let closeResult = store.closePane(id: firstSession.activePaneID, in: firstSession.id)

        XCTAssertEqual(
            closeResult,
            .session(firstSession.id, paneIDs: [firstSession.activePaneID])
        )
        XCTAssertEqual(store.groups[0].sessions.map(\.id), [secondSession.id])
        XCTAssertEqual(store.selectedSessionID, secondSession.id)
        XCTAssertEqual(store.recentlyClosed.first?.sessionID, firstSession.id)

        let reopenedID = store.reopenMostRecentlyClosed(now: Date())
        XCTAssertNotNil(reopenedID)
        XCTAssertEqual(store.selectedSessionID, reopenedID)
        XCTAssertTrue(store.recentlyClosed.isEmpty)
    }

    func testClosePaneClosesWorkspaceAfterLastRemainingSplitPaneExits() {
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let firstPaneID = store.selectedSession!.activePaneID
        let secondPaneID = store.splitActivePane(orientation: .vertical)!

        XCTAssertEqual(store.closePane(id: secondPaneID, in: session.id), .pane(secondPaneID))
        XCTAssertEqual(
            store.closePane(id: firstPaneID, in: session.id),
            .session(session.id, paneIDs: [firstPaneID])
        )

        XCTAssertTrue(store.groups[0].sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testUpdateActivePaneSyncsSessionMetadata() throws {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let paneID = store.selectedSession!.activePaneID
        let workingDirectory = try makeTemporaryDirectory()

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            title: "vim Package.swift",
            workingDirectory: workingDirectory.path
        )

        XCTAssertEqual(store.selectedSession?.title, "vim Package.swift")
        XCTAssertEqual(
            store.selectedSession?.workingDirectory,
            workingDirectory.path
        )
        XCTAssertEqual(store.selectedSession?.activePane?.title, "vim Package.swift")
    }

    func testUpdatePaneIgnoresRemoteWorkingDirectoryReport() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let paneID = store.selectedSession!.activePaneID

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            workingDirectory: "file://example.test/Users/example/Development"
        )

        XCTAssertEqual(store.selectedSession?.workingDirectory, "~")
        XCTAssertEqual(store.selectedSession?.activePane?.workingDirectory, "~")
    }

    func testUpdatePaneAcceptsLocalFileURLWorkingDirectoryReport() throws {
        let directory = try makeTemporaryDirectory()
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let paneID = store.selectedSession!.activePaneID

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            workingDirectory: directory.absoluteString
        )

        XCTAssertEqual(store.selectedSession?.workingDirectory, directory.path)
        XCTAssertEqual(store.selectedSession?.activePane?.workingDirectory, directory.path)
    }

    func testAddSessionCreatesGroupWhenNeeded() {
        let store = SessionStore(groups: [])

        let newSessionID = store.addSession(groupName: "scratch")

        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups[0].name, "scratch")
        XCTAssertEqual(store.groups[0].sessions.map(\.id), [newSessionID])
        XCTAssertEqual(store.selectedSessionID, newSessionID)
    }

    func testCloseSelectedSessionSelectsNextAvailableSession() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession, secondSession])
        ])
        store.selectedSessionID = firstSession.id

        store.closeSession(id: firstSession.id)

        XCTAssertEqual(store.groups[0].sessions.map(\.id), [secondSession.id])
        XCTAssertEqual(store.selectedSessionID, secondSession.id)
    }

    func testCloseSelectedMiddleSessionSelectsNextSession() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let thirdSession = TerminalSession(
            title: "third",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession, secondSession, thirdSession])
        ])
        store.selectedSessionID = secondSession.id

        store.closeSession(id: secondSession.id)

        XCTAssertEqual(store.groups[0].sessions.map(\.id), [firstSession.id, thirdSession.id])
        XCTAssertEqual(store.selectedSessionID, thirdSession.id)
    }

    func testCloseSelectedLastSessionSelectsPreviousSession() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession, secondSession])
        ])
        store.selectedSessionID = secondSession.id

        store.closeSession(id: secondSession.id)

        XCTAssertEqual(store.groups[0].sessions.map(\.id), [firstSession.id])
        XCTAssertEqual(store.selectedSessionID, firstSession.id)
    }

    func testCloseUnselectedSessionKeepsSelection() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [firstSession, secondSession])
        ])
        store.selectedSessionID = secondSession.id

        store.closeSession(id: firstSession.id)

        XCTAssertEqual(store.groups[0].sessions.map(\.id), [secondSession.id])
        XCTAssertEqual(store.selectedSessionID, secondSession.id)
    }

    func testCloseLastSessionClearsSelectionAndPreservesEmptyGroup() {
        let session = TerminalSession(
            title: "last",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [session])
        ])

        store.closeSession(id: session.id)

        XCTAssertEqual(store.groups.map(\.name), ["scratch"])
        XCTAssertTrue(store.groups[0].sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
    }

    func testCloseLastSessionInLeadingGroupSelectsSiblingSession() {
        let closingSession = TerminalSession(
            title: "closing",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let siblingSession = TerminalSession(
            title: "sibling",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "scratch", sessions: [closingSession]),
            SessionGroup(name: "main", sessions: [siblingSession])
        ])
        store.selectedSessionID = closingSession.id

        store.closeSession(id: closingSession.id)

        XCTAssertEqual(store.groups[0].sessions, [])
        XCTAssertEqual(store.groups[1].sessions.map(\.id), [siblingSession.id])
        XCTAssertEqual(store.selectedSessionID, siblingSession.id)
    }

    func testRemoveGroupOnlyRemovesEmptyGroups() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let emptyGroup = SessionGroup(name: "scratch", sessions: [])
        let populatedGroup = SessionGroup(name: "main", sessions: [session])
        let store = SessionStore(groups: [emptyGroup, populatedGroup])

        store.removeGroup(id: populatedGroup.id)

        XCTAssertEqual(store.groups.map(\.id), [emptyGroup.id, populatedGroup.id])

        store.removeGroup(id: emptyGroup.id)

        XCTAssertEqual(store.groups.map(\.id), [populatedGroup.id])
    }

    func testRemoveGroupPreservesFinalEmptyGroup() {
        let emptyGroup = SessionGroup(name: "scratch", sessions: [])
        let store = SessionStore(groups: [emptyGroup])

        store.removeGroup(id: emptyGroup.id)

        XCTAssertEqual(store.groups.map(\.id), [emptyGroup.id])
    }

    func testSelectNextSessionWrapsAcrossGroups() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let thirdSession = TerminalSession(
            title: "third",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession, secondSession]),
            SessionGroup(name: "scratch", sessions: [thirdSession])
        ])
        store.selectedSessionID = thirdSession.id

        store.selectNextSession()

        XCTAssertEqual(store.selectedSessionID, firstSession.id)
    }

    func testSelectPreviousSessionWrapsAcrossGroups() {
        let firstSession = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let secondSession = TerminalSession(
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [firstSession]),
            SessionGroup(name: "scratch", sessions: [secondSession])
        ])
        store.selectedSessionID = firstSession.id

        store.selectPreviousSession()

        XCTAssertEqual(store.selectedSessionID, secondSession.id)
    }

    func testSessionCyclingSelectsFirstSessionWhenSelectionIsMissing() {
        let session = TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        store.selectedSessionID = nil

        store.selectNextSession()

        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testSetActivePaneSyncsSessionChromeThroughFacade() {
        // Guards the deliberate consistency fix: mouse-focus (setActivePane) now
        // syncs session title / workingDirectory to the focused pane, matching the
        // keyboard focusPane / split / close paths. Pinned at the facade so the
        // live GhosttySurfaceView.becomeFirstResponder path stays covered, not just
        // the reducer in isolation.
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "first",
            workingDirectory: "/a",
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        store.setActivePane(id: second.id, in: session.id)

        XCTAssertEqual(store.selectedSession?.activePaneID, second.id)
        XCTAssertEqual(store.selectedSession?.workingDirectory, "/b")
        XCTAssertEqual(store.selectedSession?.title, "second")
    }

    func testSetActivePaneDoesNotOverrideUserEditedTitle() {
        // The chrome sync must respect isTitleUserEdited: workingDirectory follows
        // the focused pane, but a user-named workspace keeps its title.
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "My Workspace",
            workingDirectory: "/a",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        store.setActivePane(id: second.id, in: session.id)

        XCTAssertEqual(store.selectedSession?.workingDirectory, "/b")
        XCTAssertEqual(store.selectedSession?.title, "My Workspace")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-session-store-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("awesomux-session-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return condition()
    }

    private func splitIDs(in layout: TerminalPaneLayout) -> [TerminalSplit.ID] {
        switch layout {
        case .pane:
            return []
        case let .split(split):
            return [split.id] + splitIDs(in: split.first) + splitIDs(in: split.second)
        case .documentGroup:
            return []
        }
    }

    func testFocusPaneByIndexSelectsPaneAndSyncsChrome() {
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/a",
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        store.selectedSessionID = session.id

        store.focusPane(at: 2)

        XCTAssertEqual(store.selectedSession?.activePaneID, second.id)
        XCTAssertEqual(store.selectedSession?.workingDirectory, "/b")
    }
}

@MainActor
@Suite("SessionStore bridge process errors")
struct SessionStoreBridgeProcessErrorTests {
    @Test("records bridge loss as a pane error, not generic attention")
    func recordsBridgeLossAsPaneError() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let pane = store.selectedSession?.layout.pane(id: session.activePaneID)
        #expect(recorded)
        #expect(pane?.agentExecutionState == .error)
        #expect(pane?.attentionReason == nil)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("focused bridge loss does not bump unread")
    func focusedBridgeLossDoesNotBumpUnread() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}

@MainActor
@Suite("SessionStore sibling pane exit errors")
struct SessionStoreSiblingPaneExitErrorTests {
    @Test("marks running session as needs attention")
    func marksRunningSessionNeedsAttention() {
        let session = makeSession(state: .running)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .needsAttention)
    }

    @Test("increments unread count when terminal is unfocused")
    func incrementsUnreadCountWhenUnfocused() {
        let session = makeSession(state: .running, unreadNotificationCount: 2)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.unreadNotificationCount == 3)
        // Pins the latent fix: the app-wide total must follow the per-session
        // bump. The pre-extraction monolith updated the session count but left
        // `unreadNotificationTotal` stale until the next structural rebuild.
        #expect(store.unreadNotificationTotal == 3)
    }

    @Test("does not increment unread count when terminal is focused")
    func doesNotIncrementUnreadCountWhenFocused() {
        let session = makeSession(state: .running, unreadNotificationCount: 2)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: true
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .needsAttention)
        #expect(store.selectedSession?.unreadNotificationCount == 2)
        #expect(store.unreadNotificationTotal == 2)
    }

    @Test("preserves existing error state without bumping unread")
    func preservesExistingErrorState() {
        let session = makeSession(state: .error, unreadNotificationCount: 1)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .error)
        // No transition into `.needsAttention` happened (session was already
        // in `.error`), so repeated sibling-exit callbacks must not inflate
        // the badge count.
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("does not bump unread when already in needs attention")
    func preservesNeedsAttentionStateWithoutBumpingUnread() {
        let session = makeSession(state: .needsAttention, unreadNotificationCount: 1)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .needsAttention)
        // Already in `.needsAttention` — a second sibling exit must not
        // re-bump the badge count.
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("returns false for missing session and leaves all sessions untouched")
    func returnsFalseForMissingSession() {
        let firstSession = makeSession(state: .running, unreadNotificationCount: 0)
        let secondSession = makeSession(
            state: .needsAttention,
            unreadNotificationCount: 4
        )
        let store = SessionStore(groups: [
            SessionGroup(
                name: "awesoMux",
                sessions: [firstSession, secondSession]
            )
        ])

        let recorded = store.recordSiblingPaneExitError(
            in: UUID(),
            exitingPaneID: UUID(),
            terminalIsFocused: false
        )

        #expect(!recorded)
        let storedFirst = store.session(id: firstSession.id)
        let storedSecond = store.session(id: secondSession.id)
        #expect(storedFirst?.agentState == .running)
        #expect(storedFirst?.unreadNotificationCount == 0)
        #expect(storedSecond?.agentState == .needsAttention)
        #expect(storedSecond?.unreadNotificationCount == 4)
        // No session matched, so nothing should touch the running total.
        #expect(store.unreadNotificationTotal == 4)
    }

    @Test("records the exit error on the exiting pane before it is removed")
    func recordsExitErrorOnExitingPaneBeforeRemoval() {
        // M2 (INT-504 review): pane B exits non-zero in a 2-pane split. The exit
        // handler now RECORDS the error on B while it is still in the layout,
        // BEFORE closePane removes it (record-before-removal, maintainer decision) — the
        // prior close-first ordering no-oped because the dead pane was already
        // gone. The badge lands on the correct (exiting) pane and never on the
        // innocent survivor A.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB)
            )),
            activePaneID: paneB.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        // Record FIRST, while B is still present (mirrors the corrected
        // exit-handler ordering: record before the dead pane is removed).
        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason
                == .processError
        )
        // The survivor is never badged.
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)

        // Then closePane removes B and collapses the split onto A.
        _ = store.closePane(id: paneB.id, in: session.id)
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

    @Test("badges the exiting pane when it is still held in the layout")
    func badgesExitingPaneWhenStillPresent() {
        // Forward-compat with INT-506: when the exiting pane is still in the
        // layout (a held-dead pane), the error attaches to IT, never a sibling.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB)
            )),
            activePaneID: paneA.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason == .processError
        )
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

    private func makeSession(
        state: AgentState,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: state,
            unreadNotificationCount: unreadNotificationCount
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}

@MainActor
@Suite("SessionStore terminal backend metadata")
struct SessionStoreTerminalBackendMetadataTests {
    @Test("writes and persists metadata to the pane")
    func writesMetadata() {
        let session = makeSession()
        let store = makeStore(session)
        let metadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

        let result = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: metadata
        )

        #expect(result)
        #expect(
            store.selectedSession?.layout.pane(id: session.activePaneID)?
                .terminalBackendMetadata == metadata
        )
    }

    @Test("no-op returns true and preserves the value when metadata already matches")
    func noOpWhenUnchanged() {
        let session = makeSession()
        let store = makeStore(session)
        let metadata = TerminalBackendMetadata(rawValue: "amx:v1:established")
        _ = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: metadata
        )

        let result = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: metadata
        )

        #expect(result)
        #expect(
            store.selectedSession?.layout.pane(id: session.activePaneID)?
                .terminalBackendMetadata == metadata
        )
    }

    @Test("returns false for an unknown pane and mutates nothing")
    func falseForUnknownPane() {
        let session = makeSession()
        let store = makeStore(session)

        let result = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: UUID(),
            metadata: TerminalBackendMetadata(rawValue: "amx:v1:established")
        )

        #expect(!result)
        #expect(
            store.selectedSession?.layout.pane(id: session.activePaneID)?
                .terminalBackendMetadata == .empty
        )
    }

    // M3: the bridge error-latch and local-shell fallback paths clear the
    // established metadata to `.empty` so the Path Bar's cwd poll stops keying
    // the pane as a live bridge pane (it would otherwise poll a dead session id
    // every ~4s forever). Those NSView callers are AppKit-bound; this asserts the
    // facade primitive they call behaves: established → .empty clears.
    @Test("clearing established metadata to .empty resets the pane")
    func clearsEstablishedToEmpty() {
        let session = makeSession()
        let store = makeStore(session)
        _ = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: TerminalBackendMetadata(rawValue: "amx:v1:established")
        )

        let result = store.updateTerminalBackendMetadata(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: .empty
        )

        #expect(result)
        #expect(
            store.selectedSession?.layout.pane(id: session.activePaneID)?
                .terminalBackendMetadata == .empty
        )
    }

    private func makeSession() -> TerminalSession {
        TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}
