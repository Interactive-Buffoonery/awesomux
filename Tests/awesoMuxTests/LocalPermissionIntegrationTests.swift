@testable import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Local permission file integration")
struct LocalPermissionIntegrationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("permission-integration-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func request(_ endpoint: LocalPermissionEndpoint, session: String) throws -> LocalPermissionRequest {
        LocalPermissionRequest(
            target: endpoint.target, providerSessionID: session, invocationID: UUID(), toolUseID: nil,
            helperPID: getpid(), helperStartMicroseconds: try #require(LocalPermissionFiles.processStartMicroseconds(getpid())),
            expiresAt: Date().addingTimeInterval(120), tool: "Bash", summary: "echo fixture"
        )
    }

    // Failure modes: compact surfaces can block without cards; stale or absent
    // context can attribute a background transition to the focused request.
    @Test(arguments: [false, true], [nil, .floatingPanel, .popUpTerminal] as [CompactTerminalKind?])
    func cardPresentationEligibility(remote: Bool, compact: CompactTerminalKind?) throws {
        let plan: PaneExecutionPlan =
            remote
            ? .ssh(SSHExecution(target: try #require(RemoteTarget(user: "fixture", host: "example.test")))) : .local
        #expect(LocalPermissionPresentation.isEligible(executionPlan: plan, compactTerminalKind: compact) == (!remote && compact == nil))
    }

    @Test(
        "cached compact shell gains fresh authority on promotion and loses it on return",
        arguments: [CompactTerminalKind.floatingPanel, .popUpTerminal], [false, true])
    func cachedSurfacePromotion(compact: CompactTerminalKind, sameStore: Bool) async throws {
        let session = TerminalSession(title: "Promoted", workingDirectory: "/tmp")
        let pane = try #require(session.layout.pane(id: session.activePaneID))
        let compactStore = SessionStore(groups: [SessionGroup(name: "Compact", sessions: [session])], selectedSessionID: session.id)
        compactStore.compactTerminalKind = compact
        let mainStore =
            sameStore
            ? compactStore : SessionStore(groups: [SessionGroup(name: "Main", sessions: [session])], selectedSessionID: session.id)
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: compactStore, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        let launch = view.agentRuntimeEnvironment()
        let shellEnvironment = launch.environment
        let descriptor = LocalPermissionEndpoint.environmentFile(for: launch.eventFileURL)
        #expect(shellEnvironment[LocalPermissionEndpoint.environmentKey] == descriptor.path)
        #expect(!FileManager.default.fileExists(atPath: descriptor.path))
        #expect(view.surface == nil)

        mainStore.compactTerminalKind = nil
        let promoted = runtime.surfaceView(
            sessionStore: mainStore, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        #expect(promoted === view)
        #expect(promoted.surface == nil)
        let endpoint = try #require(LocalPermissionEndpoint.parse(shellEnvironment[LocalPermissionEndpoint.environmentKey]))
        #expect(endpoint.target.workspaceID == session.id && endpoint.target.paneID == pane.id)
        let old = try request(endpoint, session: "A")
        #expect(LocalPermissionFiles.write(old, at: endpoint.file("req", id: old.invocationID)))
        try #require(await waitUntilEventually { runtime.localPermissionCoordinator.cards[pane.id]?.request == old })
        _ = runtime.surfaceView(
            sessionStore: mainStore, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        #expect(LocalPermissionEndpoint.parse(shellEnvironment[LocalPermissionEndpoint.environmentKey])?.target == endpoint.target)

        compactStore.compactTerminalKind = compact
        _ = runtime.surfaceView(
            sessionStore: compactStore, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        #expect(!FileManager.default.fileExists(atPath: descriptor.path))
        #expect(!FileManager.default.fileExists(atPath: endpoint.directory))
        #expect(runtime.localPermissionCoordinator.cards[pane.id] == nil)
        mainStore.compactTerminalKind = nil
        _ = runtime.surfaceView(
            sessionStore: mainStore, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        let renewed = try #require(LocalPermissionEndpoint.parse(shellEnvironment[LocalPermissionEndpoint.environmentKey]))
        #expect(renewed.target.version != endpoint.target.version)
        #expect(LocalPermissionFiles.write(old, at: renewed.file("req", id: old.invocationID)))
        let fresh = try request(renewed, session: "B")
        #expect(LocalPermissionFiles.write(fresh, at: renewed.file("req", id: fresh.invocationID)))
        try #require(await waitUntilEventually { runtime.localPermissionCoordinator.cards[pane.id]?.request == fresh })
        #expect(
            runtime.localPermissionCoordinator.queuedCounts[pane.id] == nil || runtime.localPermissionCoordinator.queuedCounts[pane.id] == 0
        )
    }

    @Test(
        "cached surface renews authority for owner and identity changes", arguments: ["owner", "workspace", "terminal", "pane", "remote"])
    func cachedSurfaceAuthorityReplacement(change: String) async throws {
        var session = TerminalSession(title: "Original", workingDirectory: "/tmp")
        var pane = try #require(session.layout.pane(id: session.activePaneID))
        let store = SessionStore(groups: [SessionGroup(name: "Main", sessions: [session])], selectedSessionID: session.id)
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: store, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        let shellEnvironment = view.agentRuntimeEnvironment().environment
        let descriptor = try #require(shellEnvironment[LocalPermissionEndpoint.environmentKey])
        let first = try #require(LocalPermissionEndpoint.parse(descriptor))
        let old = try request(first, session: "A")
        #expect(LocalPermissionFiles.write(old, at: first.file("req", id: old.invocationID)))
        try #require(await waitUntilEventually { runtime.localPermissionCoordinator.cards[pane.id]?.request == old })
        let oldPaneID = pane.id
        var destination = store
        switch change {
        case "owner":
            session.title = "New owner"
            destination = SessionStore(groups: [SessionGroup(name: "Other", sessions: [session])], selectedSessionID: session.id)
        case "workspace":
            session = TerminalSession(title: "Destination", workingDirectory: "/tmp", layout: .pane(pane), activePaneID: pane.id)
            destination = SessionStore(groups: [SessionGroup(name: "Other", sessions: [session])], selectedSessionID: session.id)
        case "terminal": pane.terminalSessionID = .generate()
        case "pane": pane = TerminalPane(title: "Replacement", workingDirectory: "/tmp", executionPlan: .local)
        case "remote":
            pane.executionPlan = .ssh(SSHExecution(target: try #require(RemoteTarget(user: "fixture", host: "example.test"))))
        default: Issue.record("Unexpected replacement case")
        }
        view.update(sessionStore: destination, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        #expect(!FileManager.default.fileExists(atPath: first.directory))
        #expect(runtime.localPermissionCoordinator.cards[oldPaneID] == nil)
        if change == "remote" || change == "pane" {
            #expect(LocalPermissionEndpoint.parse(descriptor) == nil)
            if change == "pane" { return }
            pane.executionPlan = .local
            view.update(
                sessionStore: destination, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        }
        let replacement = try #require(LocalPermissionEndpoint.parse(descriptor))
        #expect(replacement.target.version != first.target.version)
        #expect(replacement.target.workspaceID == session.id)
        #expect(LocalPermissionFiles.write(old, at: replacement.file("req", id: old.invocationID)))
        let fresh = try request(replacement, session: "B")
        #expect(LocalPermissionFiles.write(fresh, at: replacement.file("req", id: fresh.invocationID)))
        try #require(await waitUntilEventually { runtime.localPermissionCoordinator.cards[pane.id]?.request == fresh })
    }

    @Test("remote launch has no local descriptor or permission authority")
    func remoteSurfaceDescriptor() throws {
        let session = TerminalSession(title: "Remote", workingDirectory: "/tmp")
        var pane = try #require(session.layout.pane(id: session.activePaneID))
        pane.executionPlan = .ssh(SSHExecution(target: try #require(RemoteTarget(user: "fixture", host: "example.test"))))
        let store = SessionStore(groups: [SessionGroup(name: "Remote", sessions: [session])], selectedSessionID: session.id)
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: store, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        let launch = view.agentRuntimeEnvironment()
        #expect(launch.environment[LocalPermissionEndpoint.environmentKey] == nil)
        #expect(!FileManager.default.fileExists(atPath: LocalPermissionEndpoint.environmentFile(for: launch.eventFileURL).path))
        pane.executionPlan = .local
        view.update(sessionStore: store, session: session, pane: pane, enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false)
        #expect(!FileManager.default.fileExists(atPath: LocalPermissionEndpoint.environmentFile(for: launch.eventFileURL).path))
    }

    @Test("announcement context resolves current workspace and pane position, or suppresses")
    func liveAnnouncementContext() throws {
        let session = TerminalSession(title: "Original", workingDirectory: "/tmp")
        let store = SessionStore(groups: [SessionGroup(name: "Fixture", sessions: [session])], selectedSessionID: session.id)
        let secondPane = try #require(store.splitActivePane(orientation: .horizontal))
        let target = LocalPermissionTarget(runtimeID: UUID(), workspaceID: session.id, paneID: secondPane, version: UUID())
        let context = try #require(LocalPermissionPresentation.context(for: target, in: store))
        #expect(context.workspaceName == "Original")
        #expect(context.panePosition == 2)
        store.renameSession(id: session.id, title: "Updated")
        #expect(LocalPermissionPresentation.context(for: target, in: store)?.workspaceName == "Updated")
        #expect(store.movePane(id: secondPane, toWorkspaceEdge: .left, in: session.id))
        #expect(LocalPermissionPresentation.context(for: target, in: store)?.panePosition == 1)
        let foreign = LocalPermissionTarget(runtimeID: target.runtimeID, workspaceID: UUID(), paneID: secondPane, version: target.version)
        #expect(LocalPermissionPresentation.context(for: foreign, in: store) == nil)
        store.closeSession(id: session.id)
        #expect(LocalPermissionPresentation.context(for: target, in: store) == nil)
        #expect(LocalPermissionPresentation.Context(workspaceName: " \u{202e}\u{0007}", panePosition: 1) == nil)
        #expect(
            LocalPermissionPresentation.Context(workspaceName: "  Work\u{202e}space\u{0007}  ", panePosition: 2)?.workspaceName
                == "Workspace")
    }

    @Test("announcements name live context and distinct invocations without request content")
    func contextualAnnouncements() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var messages: [String] = []
        var workspaceName: String? = "Original"
        let coordinator = LocalPermissionCoordinator(announcement: { messages.append($0) })
        defer { coordinator.retireAll() }
        let pane = UUID()
        let endpoint = try #require(
            coordinator.install(
                workspaceID: UUID(), paneID: pane, eventFile: root.appendingPathComponent("events.jsonl"),
                presentationContext: { _ in
                    workspaceName.flatMap { LocalPermissionPresentation.Context(workspaceName: $0, panePosition: 2) }
                }
            ))
        let first = try request(endpoint, session: "A")
        #expect(LocalPermissionFiles.write(first, at: endpoint.file("req", id: first.invocationID)))
        try #require(await waitUntilEventually { coordinator.cards[pane]?.request == first })
        #expect(messages.count == 1)
        #expect(messages.first?.contains("Original, pane 2, request 1.") == true)
        let second = try request(endpoint, session: "A")
        #expect(LocalPermissionFiles.write(second, at: endpoint.file("req", id: second.invocationID)))
        try #require(await waitUntilEventually { coordinator.queuedCounts[pane] == 1 })
        #expect(messages.last?.contains("Original, pane 2, request 2.") == true)
        workspaceName = "Renamed"
        coordinator.observe(.init(source: .claudeCode, phase: .stop, providerSessionID: "A", timestamp: Date()), paneID: pane)
        #expect(messages.suffix(2).allSatisfy { $0.contains("Renamed, pane 2, request") && $0.contains("Permission request cancelled") })
        #expect(messages.contains { $0.contains("request 1. Permission request cancelled") })
        #expect(messages.contains { $0.contains("request 2. Permission request cancelled") })
        #expect(messages.allSatisfy { !$0.contains(first.summary) && !$0.contains(first.tool) })
        workspaceName = nil
        let count = messages.count
        let third = try request(endpoint, session: "A")
        #expect(LocalPermissionFiles.write(third, at: endpoint.file("req", id: third.invocationID)))
        try #require(await waitUntilEventually { coordinator.cards[pane]?.request == third })
        #expect(messages.count == count)
    }

    @Test("moving and returning renews the stable descriptor and retires old authority")
    func moveAndReturn() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var resolvedWorkspaces: [UUID] = []
        let coordinator = LocalPermissionCoordinator(announcement: { _ in })
        defer { coordinator.retireAll() }
        let pane = UUID()
        let workspace = UUID()
        let eventFile = root.appendingPathComponent("events.jsonl")
        let first = try #require(
            coordinator.install(
                workspaceID: workspace, paneID: pane, eventFile: eventFile,
                presentationContext: { target in
                    resolvedWorkspaces.append(target.workspaceID)
                    return LocalPermissionPresentation.Context(workspaceName: "Fixture", panePosition: 1)
                }))
        let original = try request(first, session: "A")
        #expect(LocalPermissionFiles.write(original, at: first.file("req", id: original.invocationID)))
        #expect(await waitUntilEventually { coordinator.cards[pane]?.request == original })

        #expect(resolvedWorkspaces == [workspace])
        let destination = UUID()
        coordinator.move(paneID: pane, to: destination)
        let descriptor = LocalPermissionEndpoint.environmentFile(for: eventFile)
        let moved = try #require(LocalPermissionFiles.read(LocalPermissionEndpoint.self, at: descriptor))
        #expect(moved.target.workspaceID == destination)
        #expect(moved.target.paneID == pane)
        #expect(moved.target.runtimeID == first.target.runtimeID)
        #expect(moved.target.version != first.target.version)
        #expect(!FileManager.default.fileExists(atPath: first.directory))
        #expect(coordinator.cards[pane] == nil)
        let fresh = try request(moved, session: "B")
        #expect(LocalPermissionFiles.write(fresh, at: moved.file("req", id: fresh.invocationID)))
        #expect(await waitUntilEventually { coordinator.cards[pane]?.request == fresh })

        #expect(resolvedWorkspaces == [workspace, destination])
        coordinator.move(paneID: pane, to: workspace)
        let returned = try #require(LocalPermissionFiles.read(LocalPermissionEndpoint.self, at: descriptor))
        #expect(returned.target.workspaceID == workspace)
        #expect(returned.target.version != first.target.version && returned.target.version != moved.target.version)
        #expect(coordinator.cards[pane] == nil)
    }

    @Test("delayed session evidence rediscovers unchanged fallback and ACK precedes withdrawal")
    func delayedSessionAndReceipt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var completedScans = 0
        var messages: [String] = []
        let coordinator = LocalPermissionCoordinator(
            directoryScanCompleted: { _ in completedScans += 1 }, announcement: { messages.append($0) })
        defer { coordinator.retireAll() }
        let pane = UUID()
        let endpoint = try #require(
            coordinator.install(
                workspaceID: UUID(), paneID: pane, eventFile: root.appendingPathComponent("events.jsonl"),
                presentationContext: { _ in LocalPermissionPresentation.Context(workspaceName: "Receipt", panePosition: 1) }))
        coordinator.observe(.init(source: .claudeCode, phase: .sessionStart, providerSessionID: "A", timestamp: Date()), paneID: pane)
        let pending = try request(endpoint, session: "B")
        let file = endpoint.file("req", id: pending.invocationID)
        #expect(LocalPermissionFiles.write(pending, at: file))
        let unchanged = try Data(contentsOf: file)
        // Observe actual scan completion before changing session eligibility.
        #expect(await waitUntilEventually { completedScans > 0 })
        #expect(coordinator.cards[pane] == nil)
        coordinator.observe(.init(source: .claudeCode, phase: .sessionStart, providerSessionID: "B", timestamp: Date()), paneID: pane)
        #expect(await waitUntilEventually(deadline: .seconds(2)) { coordinator.cards[pane]?.request == pending })
        #expect(try Data(contentsOf: file) == unchanged)
        try await Task.sleep(for: .milliseconds(400))  // Deliberate successor gesture cooldown.
        coordinator.decide(pending.identity, choice: .deny)
        #expect(messages.contains { $0.contains("Deny once recorded on Mac") })
        #expect(
            await waitUntilEventually {
                LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: pending.invocationID))?.state
                    == .delivering
            })
        // Real helper writes ACK then withdraws req immediately after stdout.
        #expect(LocalPermissionFiles.write(pending.identity, at: endpoint.file("ack", id: pending.invocationID)))
        unlink(file.path)
        #expect(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .delivered })
        #expect(messages.last?.contains("Receipt, pane 1, request 1.") == true)
        #expect(messages.last?.contains("Answer delivered to Claude hook. Tool execution is unconfirmed.") == true)
    }

    @Test("delayed old admission preserves session ordering and rediscovers unchanged fallback")
    func delayedAdmissionAndUnchangedFallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var completedScans = 0
        let coordinator = LocalPermissionCoordinator(directoryScanCompleted: { _ in completedScans += 1 })
        defer { coordinator.retireAll() }
        let pane = UUID()
        let endpoint = try #require(
            coordinator.install(workspaceID: UUID(), paneID: pane, eventFile: root.appendingPathComponent("events.jsonl")))
        try #require(await waitUntilEventually { completedScans > 0 })
        coordinator.observe(.init(source: .claudeCode, phase: .sessionStart, providerSessionID: "A", timestamp: Date()), paneID: pane)
        let old = try request(endpoint, session: "A")
        let sessionStart = old.issuedAt.addingTimeInterval(0.01)
        // B starts after A's issuance, but its telemetry remains buffered.
        try #require(await waitUntilEventually { Date() > sessionStart })
        let successor = try request(endpoint, session: "B")
        let successorFile = endpoint.file("req", id: successor.invocationID)
        let scansBeforeSuccessor = completedScans
        #expect(LocalPermissionFiles.write(successor, at: successorFile))
        let unchanged = try Data(contentsOf: successorFile)
        try #require(await waitUntilEventually { completedScans > scansBeforeSuccessor })
        #expect(coordinator.cards[pane] == nil)

        // Only now admit the still-live A hook: T1 < B's start T2 < admission T3.
        #expect(LocalPermissionFiles.write(old, at: endpoint.file("req", id: old.invocationID)))
        try #require(await waitUntilEventually { coordinator.cards[pane]?.request == old })
        #expect(coordinator.cards[pane]?.outcome.state == .pending)
        coordinator.observe(.init(source: .claudeCode, phase: .sessionStart, providerSessionID: "B", timestamp: sessionStart), paneID: pane)
        #expect(
            await waitUntilEventually(deadline: .seconds(2)) {
                coordinator.cards[pane]?.request == successor && coordinator.cards[pane]?.outcome.state == .pending
                    && LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: old.invocationID))?.state
                        == .cancelled
            })
        #expect(try Data(contentsOf: successorFile) == unchanged)
        #expect(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: old.invocationID))?.choice == nil)
    }

    @Test("terminal fallback publication retries after a blocked path without reopening")
    func terminalPublicationRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = LocalPermissionCoordinator()
        defer { coordinator.retireAll() }
        let pane = UUID()
        let endpoint = try #require(
            coordinator.install(workspaceID: UUID(), paneID: pane, eventFile: root.appendingPathComponent("events.jsonl")))
        let pending = try request(endpoint, session: "A")
        #expect(LocalPermissionFiles.write(pending, at: endpoint.file("req", id: pending.invocationID)))
        #expect(await waitUntilEventually { coordinator.cards[pane]?.request == pending })
        let decision = endpoint.file("dec", id: pending.invocationID)
        try FileManager.default.createDirectory(at: decision, withIntermediateDirectories: false)
        coordinator.observe(.init(source: .claudeCode, phase: .stop, providerSessionID: "A", timestamp: Date()), paneID: pane)
        #expect(coordinator.cards[pane]?.outcome.state == .cancelled)
        // Keep the conflicting path through at least one pump/publication attempt.
        try await Task.sleep(for: .milliseconds(400))
        try FileManager.default.removeItem(at: decision)
        #expect(
            await waitUntilEventually(deadline: .seconds(3)) {
                LocalPermissionFiles.read(LocalPermissionOutcome.self, at: decision)?.state == .cancelled
            })
        // A late receipt cannot resurrect a closed outcome.
        #expect(LocalPermissionFiles.write(pending.identity, at: endpoint.file("ack", id: pending.invocationID)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.cards[pane]?.outcome.state == .cancelled)
        #expect(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: decision)?.choice == nil)
    }
}
