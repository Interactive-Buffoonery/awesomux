import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("DaemonStateResolver")
struct DaemonStateResolverTests {
    private func id(_ s: String) -> TerminalSessionID { TerminalSessionID(rawValue: s)! }
    private let a = "11111111-1111-4111-8111-111111111111"

    private func daemon(_ raw: String, pid: Int32 = 1, created: Int = 0, clients: Int = 0) -> LiveDaemon {
        LiveDaemon(id: id(raw), pid: pid, createdEpoch: created, clients: clients)
    }

    private func resolve(
        live: [LiveDaemon], idle: [TerminalSessionID: Bool] = [:],
        owned: Set<TerminalSessionID> = [], restorable: Set<TerminalSessionID> = [],
        owners: [TerminalSessionID: String] = [:], pinned: Set<TerminalSessionID> = [],
        livePresentation: [TerminalSessionID: DaemonPresentation] = [:],
        snapshotPresentation: [TerminalSessionID: DaemonPresentation] = [:],
        cap: Int? = nil, now: Int = 1000
    ) -> [DaemonRow] {
        DaemonStateResolver.resolve(.init(
            live: live, idleByID: idle, ownedByLivePane: owned, restorable: restorable,
                owners: owners, pinned: pinned, livePresentation: livePresentation,
                snapshotPresentation: snapshotPresentation, capThresholdSeconds: cap, now: now
        ))
    }

    @Test("presentation prefers live, snapshot, daemon metadata, then UUID fallback")
    func presentationPrecedence() {
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "Daemon",
            paneTitle: nil,
            groupID: nil,
            groupName: "Daemon Group",
            groupRemote: nil,
            agentKind: .codex
        )
        let liveDaemon = LiveDaemon(
            id: id(a), pid: 1, createdEpoch: 0, clients: 0,
            cwd: "/daemon", recoveryMetadata: metadata
        )
        let snapshot = DaemonPresentation(
            label: "Snapshot", directory: "/snapshot", groupName: "Snapshot Group",
            agentKind: .pi, owner: "snapshot owner"
        )
        let live = DaemonPresentation(
            label: "Live", directory: "/live", groupName: "Live Group",
            agentKind: .claudeCode, owner: "live owner"
        )

        let liveRow = resolve(live: [liveDaemon], livePresentation: [id(a): live], snapshotPresentation: [id(a): snapshot])[0]
        #expect(liveRow.label == "Live")
        #expect(liveRow.directory == "/live")
        #expect(liveRow.groupName == "Live Group")
        #expect(liveRow.agentKind == .claudeCode)
        #expect(liveRow.owner == "live owner")

        let snapshotRow = resolve(live: [liveDaemon], snapshotPresentation: [id(a): snapshot])[0]
        #expect(snapshotRow.label == "Snapshot")
        #expect(snapshotRow.directory == "/snapshot")

        let daemonRow = resolve(live: [liveDaemon])[0]
        #expect(daemonRow.label == "Daemon")
        #expect(daemonRow.directory == "/daemon")
        #expect(daemonRow.groupName == "Daemon Group")
        #expect(daemonRow.agentKind == .codex)
        #expect(daemonRow.shortID == "amx:11111111")

        let fallback = resolve(live: [daemon(a)])[0]
        #expect(fallback.label == a)
        #expect(fallback.directory == nil)
    }

    @Test("live presentation disambiguates duplicate workspace labels with pane titles")
    func livePresentationDisambiguatesDuplicateLabels() {
        let paneA = TerminalPane(
            terminalSessionID: id(a), title: "api", workingDirectory: "/repo/api",
            executionPlan: .local
        )
        let paneB = TerminalPane(
            terminalSessionID: id("22222222-2222-4222-8222-222222222222"),
            title: "tests", workingDirectory: "/repo/tests", executionPlan: .local
        )
        let session = TerminalSession(
            title: "awesomux", workingDirectory: "/repo",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical, first: .pane(paneA), second: .pane(paneB)
                )), activePaneID: paneA.id
        )

        let result = DaemonPresentationProjector.live(
            groups: [SessionGroup(name: "Development", sessions: [session])]
        )

        #expect(result[paneA.terminalSessionID]?.label == "awesomux · api")
        #expect(result[paneB.terminalSessionID]?.label == "awesomux · tests")
        #expect(result[paneA.terminalSessionID]?.directory == "/repo/api")
        #expect(result[paneA.terminalSessionID]?.groupName == "Development")
    }

    @Test("live presentation keeps the first duplicate daemon identity without false disambiguation")
    func livePresentationDeduplicatesDaemonIdentity() {
        let pane = TerminalPane(terminalSessionID: id(a), title: "api", workingDirectory: "/first", executionPlan: .local)
        let first = TerminalSession(title: "awesomux", workingDirectory: "/first", layout: .pane(pane), activePaneID: pane.id)
        let duplicate = TerminalPane(terminalSessionID: id(a), title: "other", workingDirectory: "/second", executionPlan: .local)
        let second = TerminalSession(title: "awesomux", workingDirectory: "/second", layout: .pane(duplicate), activePaneID: duplicate.id)

        let result = DaemonPresentationProjector.live(groups: [SessionGroup(name: "Development", sessions: [first, second])])

        #expect(result.count == 1)
        #expect(result[id(a)]?.label == "awesomux")
        #expect(result[id(a)]?.directory == "/first")
        #expect(result[id(a)]?.owner == "awesomux · api")
    }

    @Test("daemon metadata disambiguates duplicate workspace labels with pane titles")
    func daemonMetadataDisambiguatesDuplicateLabels() {
        let second = "22222222-2222-4222-8222-222222222222"
        let firstMetadata = DaemonRecoveryMetadata(
            workspaceTitle: "awesomux", paneTitle: "api", groupID: nil,
            groupName: "Development", groupRemote: nil, agentKind: .codex
        )
        let secondMetadata = DaemonRecoveryMetadata(
            workspaceTitle: "awesomux", paneTitle: "tests", groupID: nil,
            groupName: "Development", groupRemote: nil, agentKind: .codex
        )

        let rows = resolve(live: [
            LiveDaemon(
                id: id(a), pid: 1, createdEpoch: 0, clients: 0,
                recoveryMetadata: firstMetadata
            ),
            LiveDaemon(
                id: id(second), pid: 2, createdEpoch: 0, clients: 0,
                recoveryMetadata: secondMetadata
            ),
        ])

        #expect(rows.first(where: { $0.id == id(a) })?.label == "awesomux · api")
        #expect(rows.first(where: { $0.id == id(second) })?.label == "awesomux · tests")
    }

    @Test("duplicate daemon inventory entries do not disambiguate one workspace")
    func duplicateDaemonInventoryDoesNotDisambiguateLabel() {
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "awesomux", paneTitle: "api", groupID: nil,
            groupName: "Development", groupRemote: nil, agentKind: .codex
        )
        let liveDaemon = LiveDaemon(
            id: id(a), pid: 1, createdEpoch: 0, clients: 0,
            recoveryMetadata: metadata
        )

        let rows = resolve(live: [liveDaemon, liveDaemon])

        #expect(rows.count == 1)
        #expect(rows[0].label == "awesomux")
    }

    @Test("snapshot presentation counts a transient and persisted close once")
    func snapshotPresentationDeduplicatesCloseTiers() {
        let pane = TerminalPane(
            terminalSessionID: id(a), title: "shell", workingDirectory: "/repo",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(), title: "awesomux", isTitleUserEdited: true,
            agentKind: .shell, layout: .pane(pane), activePaneID: pane.id,
            groupID: UUID(), groupName: "Development", groupRemote: nil,
            indexInGroup: 0, closedAt: Date()
        )

        let result = DaemonPresentationProjector.snapshots(
            recentlyClosed: [entry], lastClosedTransient: entry
        )

        #expect(result[pane.terminalSessionID]?.label == "awesomux")
    }
}
