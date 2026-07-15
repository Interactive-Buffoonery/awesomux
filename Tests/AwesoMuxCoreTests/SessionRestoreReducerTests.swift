import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("SessionRestoreReducer")
struct SessionRestoreReducerTests {
    @Test("a reminted duplicate pane id also gets a fresh daemon and runtime state")
    func duplicatePaneIDResetsDaemonAndRuntimeState() throws {
        let duplicateID = UUID()
        let firstTerminalSessionID = TerminalSessionID(rawValue: "first-distinct-daemon")!
        let secondTerminalSessionID = TerminalSessionID(rawValue: "second-distinct-daemon")!
        var seenSplits: Set<TerminalSplit.ID> = []
        var seenPanes: Set<TerminalPane.ID> = []
        var seenTerminalSessionIDs: Set<TerminalSessionID> = []
        let first = TerminalPane(
            id: duplicateID,
            terminalSessionID: firstTerminalSessionID,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "first-backend"),
            title: "first",
            workingDirectory: "/first",
            executionPlan: .local
        )
        let second = TerminalPane(
            id: duplicateID,
            terminalSessionID: secondTerminalSessionID,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "second-backend"),
            title: "second",
            workingDirectory: "/second",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(first),
                second: .pane(second)
            )
        )

        let result = SessionRestoreReducer.restoredLayout(
            from: layout,
            seenSplitIDs: &seenSplits,
            seenPaneIDs: &seenPanes,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            transformPane: { pane in
                var transformed = pane
                transformed.agentKind = .codex
                transformed.agentExecutionState = .waiting
                transformed.attentionReason = .userInputRequired
                transformed.unreadNotificationCount = 3
                return transformed
            }
        )

        var panes: [TerminalPane] = []
        result.layout.forEachPane { panes.append($0) }
        let restoredFirst = try #require(panes.first)
        let restoredSecond = try #require(panes.last)

        #expect(restoredFirst.id == duplicateID)
        #expect(restoredFirst.terminalSessionID == firstTerminalSessionID)
        #expect(restoredFirst.terminalBackendMetadata == first.terminalBackendMetadata)
        #expect(restoredFirst.agentExecutionState == .waiting)
        #expect(restoredFirst.attentionReason == .userInputRequired)
        #expect(restoredFirst.unreadNotificationCount == 3)

        #expect(restoredSecond.id != duplicateID)
        #expect(restoredSecond.terminalSessionID != secondTerminalSessionID)
        #expect(restoredSecond.terminalBackendMetadata == .empty)
        #expect(result.idReassignments == 2)
        #expect(restoredSecond.agentKind == .codex)
        #expect(restoredSecond.agentExecutionState == .idle)
        #expect(restoredSecond.attentionReason == nil)
        #expect(restoredSecond.unreadNotificationCount == 0)
    }

    @Test("restore clears document and active references to a duplicated pane id")
    func restoreRejectsAmbiguousPaneReferences() throws {
        let duplicateID = UUID()
        let first = TerminalPane(id: duplicateID, title: "first", workingDirectory: "/first", executionPlan: .local)
        let second = TerminalPane(id: duplicateID, title: "second", workingDirectory: "/second", executionPlan: .local)
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/ambiguous.md"),
            title: "ambiguous.md",
            associatedTerminalPaneID: duplicateID
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(first),
                second: .split(
                    TerminalSplit(
                        orientation: .horizontal,
                        first: .documentGroup(DocumentGroup(tabs: [document], selectedTabID: document.id)),
                        second: .pane(second)
                    ))
            ))
        let session = TerminalSession(
            title: "corrupt",
            workingDirectory: "/first",
            layout: layout,
            activePaneID: duplicateID
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            ))
        let restoredSession = try #require(restored.groups.first?.sessions.first)

        #expect(restoredSession.layout.firstDocumentGroup?.selectedTab?.associatedTerminalPaneID == nil)
        #expect(restoredSession.activePaneID == restoredSession.layout.firstPane?.id)
        #expect(restored.sanitizationSummary.activePaneFallbacks == 1)
    }

    @Test("restore remaps unique document and active references after a pane id collision")
    func restoreRemapsUniquePaneReferences() throws {
        let collidingID = UUID()
        let occupied = TerminalSession(
            title: "occupied",
            workingDirectory: "/occupied",
            layout: .pane(
                TerminalPane(
                    id: collidingID,
                    title: "occupied",
                    workingDirectory: "/occupied",
                    executionPlan: .local
                )),
            activePaneID: collidingID
        )
        let pane = TerminalPane(id: collidingID, title: "closed", workingDirectory: "/closed", executionPlan: .local)
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/unique.md"),
            title: "unique.md",
            associatedTerminalPaneID: collidingID
        )
        let reminted = TerminalSession(
            title: "reminted",
            workingDirectory: "/closed",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(pane),
                    second: .documentGroup(DocumentGroup(tabs: [document], selectedTabID: document.id))
                )),
            activePaneID: collidingID
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [occupied, reminted])],
                selectedSessionID: reminted.id
            ))
        let restoredSession = try #require(restored.groups.first?.sessions.last)
        let restoredPane = try #require(restoredSession.layout.firstPane)

        #expect(restoredPane.id != collidingID)
        #expect(restoredSession.activePaneID == restoredPane.id)
        #expect(restoredSession.layout.firstDocumentGroup?.selectedTab?.associatedTerminalPaneID == restoredPane.id)
    }

    @Test("restore preserves normal one-to-one pane references")
    func restorePreservesUniquePaneReferences() throws {
        let pane = TerminalPane(title: "pane", workingDirectory: "/work", executionPlan: .local)
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/normal.md"),
            title: "normal.md",
            associatedTerminalPaneID: pane.id
        )
        let session = TerminalSession(
            title: "normal",
            workingDirectory: "/work",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal,
                    first: .documentGroup(DocumentGroup(tabs: [document], selectedTabID: document.id)),
                    second: .pane(pane)
                )),
            activePaneID: pane.id
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            ))
        let restoredSession = try #require(restored.groups.first?.sessions.first)

        #expect(restoredSession.activePaneID == pane.id)
        #expect(restoredSession.layout.firstDocumentGroup?.selectedTab?.associatedTerminalPaneID == pane.id)
    }

    @Test("restore folds current-schema document groups before remapping associations")
    func restoreNormalizesCurrentSchemaDocumentGroups() throws {
        let firstPane = TerminalPane(
            title: "first", workingDirectory: "/first", executionPlan: .local)
        let secondPane = TerminalPane(
            title: "second", workingDirectory: "/second", executionPlan: .local)
        let firstDocument = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/first.md"),
            title: "first.md",
            associatedTerminalPaneID: firstPane.id
        )
        let secondDocument = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/second.md"),
            title: "second.md",
            associatedTerminalPaneID: secondPane.id
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(firstPane),
                        second: .documentGroup(
                            DocumentGroup(
                                tabs: [firstDocument], selectedTabID: firstDocument.id))
                    )),
                second: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(secondPane),
                        second: .documentGroup(
                            DocumentGroup(
                                tabs: [secondDocument], selectedTabID: secondDocument.id))
                    ))
            ))
        let session = TerminalSession(
            title: "corrupt",
            workingDirectory: "/first",
            layout: layout,
            activePaneID: firstPane.id
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            ))
        let restoredSession = try #require(restored.groups.first?.sessions.first)
        let group = try #require(restoredSession.layout.firstDocumentGroup)

        #expect(group.tabs.map(\.id) == [firstDocument.id, secondDocument.id])
        #expect(group.selectedTabID == firstDocument.id)
        #expect(group.tabs.map(\.associatedTerminalPaneID) == [firstPane.id, secondPane.id])
        #expect(restoredSession.layout.paneIDs == [firstPane.id, secondPane.id])
    }

    @Test("restoredAgentExecutionState maps every case")
    func restoredAgentExecutionStateMapsEveryCase() {
        // .waiting is the only state that round-trips (live hook side-channel
        // signal that survives restart); everything else clamps to .idle
        // because a restored session has no live process to reattach to.
        // Per-case policy spelled out (not derived from allCases) so a new
        // case fails here and forces a test-time decision, mirroring the
        // production switch's compile-time exhaustiveness.
        let policy: [AgentExecutionState: AgentExecutionState] = [
            .idle: .idle,
            .running: .idle,
            .waiting: .waiting,
            .thinking: .idle,
            .output: .idle,
            .done: .idle,
            .error: .idle,
        ]
        #expect(Set(policy.keys) == Set(AgentExecutionState.allCases))
        for (state, expected) in policy {
            #expect(SessionRestoreReducer.restoredAgentExecutionState(state) == expected)
        }
    }

    @Test("unique terminal-session id generation retries collisions")
    func uniqueTerminalSessionIDGenerationRetriesCollisions() throws {
        let duplicate = try #require(
            TerminalSessionID(rawValue: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        )
        let unique = try #require(
            TerminalSessionID(rawValue: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        )
        var seenTerminalSessionIDs: Set<TerminalSessionID> = [duplicate]
        var generatedIDs = [duplicate, duplicate, unique].makeIterator()

        let generated = SessionRestoreReducer.generateUniqueTerminalSessionID(
            avoiding: &seenTerminalSessionIDs,
            generate: { generatedIDs.next() ?? unique }
        )

        #expect(generated == unique)
        #expect(seenTerminalSessionIDs == [duplicate, unique])
    }

    @Test("restore sanitizes visible fields, merges duplicate groups, and preserves waiting")
    func restoreSanitizesAndPreservesWaiting() throws {
        let sharedSessionID = UUID()
        let pane = TerminalPane(id: UUID(), title: "\u{202E}", workingDirectory: "\u{0000}", executionPlan: .local)
        let dirty = TerminalSession(
            id: sharedSessionID,
            title: "\u{202E}",
            workingDirectory: "\u{0000}",
            agentKind: .codex,
            agentExecutionState: .waiting,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let duplicate = TerminalSession(
            id: sharedSessionID,
            title: "duplicate",
            workingDirectory: "~",
            agentKind: .shell
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "scratch", sessions: [dirty]),
                SessionGroup(name: "scratch\u{200B}", sessions: [duplicate])
            ],
            selectedSessionID: sharedSessionID
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(restored.groups.count == 1)
        #expect(restored.groups[0].sessions.count == 2)
        #expect(restored.groups[0].sessions[0].title == "Codex 1")
        #expect(restored.groups[0].sessions[0].workingDirectory == "~")
        #expect(restored.groups[0].sessions[0].activeAgentKind == .codex)
        #expect(restored.groups[0].sessions[0].agentExecutionState == .waiting)
        #expect(restored.groups[0].sessions[1].id != sharedSessionID)
        #expect(restored.sanitizationSummary.mergedGroups == 1)
        #expect(restored.sanitizationSummary.idReassignments == 1)
    }

    @Test("restore clears stale agent identity but keeps waiting and live prompts")
    func restoreClearsStaleAgentIdentityKeepsLiveAgentChrome() throws {
        let staleRunning = TerminalPane(
            title: "",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let staleAttention = TerminalPane(
            title: "stale-attention",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .error,
            attentionReason: .processError,
            executionPlan: .local
        )
        let waiting = TerminalPane(
            title: "waiting",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            executionPlan: .local
        )
        let livePrompt = TerminalPane(
            title: "prompt",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .split(TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(staleRunning),
                    second: .pane(staleAttention)
                )),
                second: .split(TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(waiting),
                    second: .pane(livePrompt)
                ))
            )),
            activePaneID: staleRunning.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        let restored = SessionRestoreReducer.restoredComponents(from: snapshot)
            .groups[0].sessions[0]

        #expect(restored.title == "shell 1")
        #expect(restored.activeAgentKind == .shell)
        #expect(restored.layout.pane(id: staleRunning.id)?.agentKind == .shell)
        #expect(restored.layout.pane(id: staleRunning.id)?.title == "shell 1")
        #expect(restored.layout.pane(id: staleRunning.id)?.agentExecutionState == .idle)
        #expect(restored.layout.pane(id: staleRunning.id)?.attentionReason == nil)
        #expect(restored.layout.pane(id: staleAttention.id)?.agentKind == .shell)
        #expect(restored.layout.pane(id: staleAttention.id)?.agentExecutionState == .idle)
        #expect(restored.layout.pane(id: staleAttention.id)?.attentionReason == nil)
        #expect(restored.layout.pane(id: waiting.id)?.agentKind == .claudeCode)
        #expect(restored.layout.pane(id: waiting.id)?.agentExecutionState == .waiting)
        #expect(restored.layout.pane(id: livePrompt.id)?.agentKind == .codex)
        #expect(restored.layout.pane(id: livePrompt.id)?.agentExecutionState == .idle)
        #expect(restored.layout.pane(id: livePrompt.id)?.attentionReason == .permissionPrompt)
    }

    @Test("restore reassigns duplicate group ids after name merging")
    func restoreReassignsDuplicateGroupIDsAfterNameMerging() throws {
        let sharedGroupID = UUID()
        let first = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
        let second = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(id: sharedGroupID, name: "alpha", sessions: [first]),
                SessionGroup(id: sharedGroupID, name: "beta", sessions: [second])
            ],
            selectedSessionID: nil
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(restored.groups.map(\.name) == ["alpha", "beta"])
        #expect(restored.groups[0].id == sharedGroupID)
        #expect(restored.groups[1].id != sharedGroupID)
        #expect(Set(restored.groups.map(\.id)).count == restored.groups.count)
        #expect(restored.sanitizationSummary.mergedGroups == 0)
        #expect(restored.sanitizationSummary.idReassignments == 1)
    }

    @Test("restore preserves a remote workgroup's target")
    func restorePreservesRemoteTarget() {
        let target = RemoteTarget(user: "ed", host: "box")!
        let session = TerminalSession(title: "shell 1", workingDirectory: "~", agentKind: .shell)
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "box", remote: target, sessions: [session])],
            selectedSessionID: session.id
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        // Regression: the group rebuild re-inited SessionGroup without
        // `remote:`, silently de-tagging every remote workgroup on relaunch —
        // "+ new workspace" then attached a LOCAL shell (INT-767).
        #expect(restored.groups.first?.remote == target)
    }

    @Test("duplicate group id reassignment preserves persisted group fields")
    func duplicateGroupIDReassignmentPreservesRemoteTarget() {
        let sharedGroupID = UUID()
        let target = RemoteTarget(user: "ed", host: "box")!
        let first = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
        let second = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(id: sharedGroupID, name: "alpha", sessions: [first]),
                SessionGroup(
                    id: sharedGroupID,
                    name: "box",
                    color: .teal,
                    remote: target,
                    sessions: [second]
                )
            ],
            selectedSessionID: nil
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(restored.groups.map(\.name) == ["alpha", "box"])
        #expect(restored.groups[1].id != sharedGroupID)
        #expect(restored.groups[1].color == .teal)
        #expect(restored.groups[1].remote == target)
    }

    @Test(
        "same-name merge never folds sessions across a transport boundary",
        arguments: [true, false]
    )
    func sameNameMergeRefusesTransportMismatch(remoteFirst: Bool) {
        let target = RemoteTarget(user: "ed", host: "box")!
        let localSession = TerminalSession(title: "local", workingDirectory: "~", agentKind: .shell)
        let remoteSession = TerminalSession(title: "remote", workingDirectory: "~", agentKind: .shell)
        let localGroup = SessionGroup(name: "box", sessions: [localSession])
        let remoteGroup = SessionGroup(name: "Box", remote: target, sessions: [remoteSession])
        let snapshot = SessionSnapshot(
            groups: remoteFirst ? [remoteGroup, localGroup] : [localGroup, remoteGroup],
            selectedSessionID: nil
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        // Both groups survive, renamed apart — no session may inherit the
        // other group's transport (ADR-0022), in either encounter order.
        #expect(restored.groups.count == 2)
        #expect(restored.sanitizationSummary.mergedGroups == 0)
        let restoredRemote = restored.groups.first { $0.remote != nil }
        let restoredLocal = restored.groups.first { $0.remote == nil }
        #expect(restoredRemote?.remote == target)
        #expect(restoredRemote?.sessions.map(\.title) == ["remote"])
        #expect(restoredLocal?.sessions.map(\.title) == ["local"])
        #expect(restored.groups[1].name.hasSuffix(" 2"))
        #expect(
            restored.groups[0].name.caseInsensitiveCompare(restored.groups[1].name)
                != .orderedSame
        )
        #expect(restored.sanitizationSummary.groupNameAdjustments == 1)
    }

    @Test("a synthetic disambiguated name never swallows a legitimate later group")
    func syntheticNameDodgesLegitimateLaterGroup() {
        let target = RemoteTarget(user: "ed", host: "box")!
        let localSession = TerminalSession(title: "local", workingDirectory: "~", agentKind: .shell)
        let remoteSession = TerminalSession(title: "remote", workingDirectory: "~", agentKind: .shell)
        let preexisting = TerminalSession(title: "always-two", workingDirectory: "~", agentKind: .shell)
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "name", sessions: [localSession]),
                SessionGroup(name: "name", remote: target, sessions: [remoteSession]),
                SessionGroup(name: "name 2", remote: target, sessions: [preexisting])
            ],
            selectedSessionID: nil
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        // The renamed remote group must skip "name 2" — that name already
        // belongs to a real group later in the snapshot.
        #expect(restored.groups.map(\.name) == ["name", "name 3", "name 2"])
        #expect(restored.groups.map { $0.sessions.map(\.title) } == [
            ["local"], ["remote"], ["always-two"]
        ])
        #expect(restored.sanitizationSummary.mergedGroups == 0)
    }

    @Test("same-name merge with an equal remote target still folds")
    func sameNameMergeWithEqualRemoteStillMerges() {
        let target = RemoteTarget(user: "ed", host: "box")!
        let first = TerminalSession(title: "first", workingDirectory: "~", agentKind: .shell)
        let second = TerminalSession(title: "second", workingDirectory: "~", agentKind: .shell)
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "box", remote: target, sessions: [first]),
                SessionGroup(name: "Box", remote: target, sessions: [second])
            ],
            selectedSessionID: nil
        )

        let restored = SessionRestoreReducer.restoredComponents(
            from: snapshot,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(restored.groups.count == 1)
        #expect(restored.sanitizationSummary.mergedGroups == 1)
        #expect(restored.groups[0].remote == target)
        #expect(restored.groups[0].sessions.map(\.title) == ["first", "second"])
    }
}
