import AwesoMuxCore
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

    @Test("moving and returning renews the stable descriptor and retires old authority")
    func moveAndReturn() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = LocalPermissionCoordinator()
        defer { coordinator.retireAll() }
        let pane = UUID()
        let workspace = UUID()
        let eventFile = root.appendingPathComponent("events.jsonl")
        let first = try #require(coordinator.install(workspaceID: workspace, paneID: pane, eventFile: eventFile))
        let original = try request(first, session: "A")
        #expect(LocalPermissionFiles.write(original, at: first.file("req", id: original.invocationID)))
        #expect(await waitUntilEventually { coordinator.cards[pane]?.request == original })

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
        let coordinator = LocalPermissionCoordinator(directoryScanCompleted: { _ in completedScans += 1 })
        defer { coordinator.retireAll() }
        let pane = UUID()
        let endpoint = try #require(
            coordinator.install(workspaceID: UUID(), paneID: pane, eventFile: root.appendingPathComponent("events.jsonl")))
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
        #expect(
            await waitUntilEventually {
                LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: pending.invocationID))?.state
                    == .delivering
            })
        // Real helper writes ACK then withdraws req immediately after stdout.
        #expect(LocalPermissionFiles.write(pending.identity, at: endpoint.file("ack", id: pending.invocationID)))
        unlink(file.path)
        #expect(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .delivered })
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
