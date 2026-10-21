import AwesoMuxCompanionProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

// Failure modes: a grant revoked after recording must suppress a not-yet-written
// fallback answer; fixture transport success must never change the release gate.
@Suite @MainActor struct CompanionDecisionIntegrationTests {
    @Test func productionProviderGateRemainsClosed() {
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: "2.1.302"))
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "claudeCode", version: nil))
        #expect(!LocalPermissionCoordinator.remoteDecisionsEnabled(provider: "codex", version: "future"))
    }

    @Test(arguments: [false, true], [false, true]) func revokedWinnerCannotPublishAnswer(socketTransport: Bool, afterOutput: Bool)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-decision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = LocalPermissionCoordinator(announcement: { _ in })
        defer { coordinator.retireAll() }
        let workspace = UUID(), pane = UUID()
        let endpoint = try #require(
            coordinator.install(
                workspaceID: workspace, paneID: pane,
                eventFile: root.appendingPathComponent("events.jsonl")))
        let request = LocalPermissionRequest(
            target: endpoint.target, providerSessionID: "fixture", invocationID: UUID(),
            toolUseID: nil, helperPID: getpid(),
            helperStartMicroseconds: try #require(LocalPermissionFiles.processStartMicroseconds(getpid())),
            expiresAt: Date().addingTimeInterval(120), tool: "Bash", summary: "echo fixture")
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }
        if socketTransport {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            let socketPath = try #require(endpoint.socket)
            var address = try #require(LocalPermissionFiles.address(socketPath))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(connected == 0)
            var data = try JSONEncoder().encode(request)
            data.append(10)
            let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            try #require(sent == data.count)
            try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
        } else {
            #expect(LocalPermissionFiles.write(request, at: endpoint.file("req", id: request.invocationID)))
        }

        try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .pending })
        var authorized = true
        let result = try coordinator.remoteResponse(
            answer: .init(identity: request.identity.companionIdentity, choice: .allow, retryID: UUID()),
            deviceID: UUID(), deviceName: "Phone", workspaceIDs: [workspace],
            authorize: { body in
                guard authorized else { throw LocalAPIError.permissionDenied }
                try body()
            }, eligible: { $0 == endpoint.target }, fixture: true)
        #expect(result.receipt?.state == .recorded)
        if afterOutput {
            try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == .delivering })
        }
        authorized = false
        try #require(await waitUntilEventually { coordinator.cards[pane]?.outcome.state == (afterOutput ? .unknown : .cancelled) })
        #expect(
            FileManager.default.fileExists(atPath: endpoint.file("dec", id: request.invocationID).path) == (afterOutput && !socketTransport)
        )
        if fd >= 0 {
            var byte: UInt8 = 0
            let received = recv(fd, &byte, 1, 0)
            #expect(afterOutput ? received > 0 : received <= 0)
        }
    }

    @Test func decideGrantDefaultsOffAndInvalidatesLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-grant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: root)
        let fingerprint = Data(repeating: 5, count: 32)
        let phone = try access.registerCompanion(phoneName: "Phone", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        func lease() throws -> LocalAPIAuthorizationLease {
            try access.runtimeAuthority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: fingerprint,
                operation: .connectionStatus
            ).get()
        }
        let old = try lease()
        #expect(old.decideWorkspaceIDs == nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: old) {
                Issue.record("Default grant permitted work")
            }
        }
        let workspace = UUID()
        try access.updateCompanionDecideWorkspaces(connectionID: phone.id, workspaceIDs: [workspace])
        let granted = try lease()
        #expect(granted != old)
        #expect(granted.decideWorkspaceIDs == [workspace])
        try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {}
        try access.updateCompanionDecideWorkspaces(connectionID: phone.id, workspaceIDs: nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try access.runtimeAuthority.performCompanionDecision(certificateFingerprint: fingerprint, lease: granted) {
                Issue.record("Revoked grant permitted work")
            }
        }
    }
}
