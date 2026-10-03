import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxTestSupport
import Darwin
import Foundation

struct E2EFailure: Error { let message: String }

@main
struct LocalAPIE2E {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--crash-host" {
            let host = try LocalAPIServer(profile: args[1]) { _, _ in LocalAPIResponse() }
            host.start()
            defer { host.stop() }
            FileHandle.standardOutput.write(Data("READY\n".utf8))
            try await Task.sleep(for: .seconds(60))
            return
        }
        if args.count == 2, args[0] == "--seed-native" {
            let directory = args[1]
            let sessions = ["API E2E Codex", "API E2E Claude"].map {
                TerminalSession(title: $0, workingDirectory: directory)
            }
            let seed = SessionStore(groups: [SessionGroup(name: "Local API E2E", sessions: sessions)])
            FileHandle.standardOutput.write(try JSONEncoder().encode(seed.snapshot()))
            return
        }
        guard args.count == 2 else { throw E2EFailure(message: "Expected helper path and artifact directory") }
        let helper = args[0]
        let artifact = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let first = TerminalPane(title: "Codex", workingDirectory: "/tmp", agentKind: .codex, executionPlan: .local)
        let second = TerminalPane(title: "Claude", workingDirectory: "/tmp", agentKind: .claudeCode, executionPlan: .local)
        let workspace = TerminalSession(
            title: "API E2E", workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal, first: .pane(first), second: .pane(second)
                )))
        var store = SessionStore(groups: [SessionGroup(name: "E2E", sessions: [workspace])])
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            checks.append(name)
            print("PASS: \(name)")
        }
        func event(
            _ source: AgentRuntimeSource, pane: UUID, phase: AgentRuntimePhase, session: String, state: AgentExecutionState,
            attention: AttentionReason? = nil
        ) {
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: source, executionState: state, attentionReason: attention,
                    phase: phase, eventID: UUID().uuidString, providerSessionID: session, timestamp: Date()
                ), to: store.sessionIDContainingPane(pane)!, paneID: pane)
        }
        event(.codex, pane: first.id, phase: .sessionStart, session: "codex-e2e", state: .waiting)
        event(.claudeCode, pane: second.id, phase: .sessionStart, session: "claude-e2e", state: .thinking, attention: .permissionPrompt)
        let server = try LocalAPIServer(profile: profile, authorization: { _ in nil }) { request, instance in
            if request.operation == "list_agents" {
                do { _ = try store.localAPIProviders() } catch {
                    return LocalAPIResponse(requestID: request.requestID, error: .staleTarget)
                }
            }
            store.bindLocalAPIInstance(instance)
            return LocalAPIResponse(
                requestID: request.requestID, profile: profile, appInstanceID: instance,
                capturedAt: Date(), connectionStatus: request.operation == "get_connection_status" ? .connected : nil,
                capabilities: request.operation == "get_capabilities" ? LocalAPICapabilities() : nil,
                agents: request.operation == "list_agents" ? store.localAPIAgents() : nil
            )
        }
        server.start()
        defer { server.stop() }
        func call(_ operation: LocalAPIOperation = .listAgents) async throws -> LocalAPIResponse {
            try await Task.detached {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: helper)
                process.arguments = ["--profile", profile, operation.rawValue]
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                try process.waitUntilExitEventually()
                return try LocalAPIContract.decoder().decode(LocalAPIResponse.self, from: data)
            }.value
        }
        let selected = store.selectedSessionID
        let initial = try await call()
        try LocalAPIContract.encoder().encode(initial).write(to: artifact.appendingPathComponent("initial-roster.json"))
        try check(initial.agents?.count == 2 && initial.error == nil, "helper returns two pane-grain agents")
        try check(
            initial.agents?.first(where: { $0.paneID == second.id })?.attentionReason == "permissionPrompt",
            "raw native attention reason is retained")
        try check(initial.agents?.first(where: { $0.paneID == first.id })?.state == "waiting", "native waiting state is retained")
        try check(
            store.selectedSessionID == selected
                && store.session(id: workspace.id)?.layout.pane(id: second.id)?.attentionReason == .permissionPrompt,
            "reads preserve selection and native acknowledgment")
        let original = initial.agents!.first { $0.paneID == first.id }!.targetVersion
        event(.codex, pane: first.id, phase: .promptSubmit, session: "codex-e2e", state: .thinking)
        let thinking = try await call()
        try check(
            thinking.agents?.first(where: { $0.paneID == first.id })?.targetVersion == original, "ordinary status change preserves target")
        event(.codex, pane: first.id, phase: .stop, session: "codex-e2e", state: .waiting)
        _ = store.movePaneToNewWorkspace(id: first.id, in: workspace.id)
        let movedWorkspace = store.sessionIDContainingPane(first.id)!
        try check(store.returnPaneToSourceWorkspace(sessionID: movedWorkspace), "pane returns to original workspace")
        let moved = try await call()
        try check(
            moved.agents?.first(where: { $0.paneID == first.id })?.targetVersion != original,
            "move away/back between reads invalidates target")
        let beforeProviderChange = moved.agents!.first { $0.paneID == first.id }!.targetVersion
        store.applyDetectedAgentState(
            id: workspace.id, paneID: first.id, detectedState: nil, agentKind: .claudeCode, clearsAttention: false)
        store.applyDetectedAgentState(id: workspace.id, paneID: first.id, detectedState: nil, agentKind: .codex, clearsAttention: false)
        let restoredProvider = try await call()
        try check(
            restoredProvider.agents?.first(where: { $0.paneID == first.id })?.targetVersion != beforeProviderChange,
            "provider flipback between reads invalidates target")
        let beforeRestart = moved.agents!.first { $0.paneID == first.id }!.targetVersion
        event(.codex, pane: first.id, phase: .sessionStart, session: "codex-replacement", state: .waiting)
        let replacement = try await call()
        try check(
            replacement.agents?.first(where: { $0.paneID == first.id })?.targetVersion != beforeRestart,
            "same-provider replacement invalidates target")
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let transport = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("script/local-api-e2e/transport.py")
            process.arguments = [
                "python3", transport.path, profile, artifact.appendingPathComponent("transport.json").path, helper,
                CommandLine.arguments[0],
            ]
            try process.run()
            try process.waitUntilExitEventually()
            guard process.terminationStatus == 0 else { throw E2EFailure(message: "transport scenarios failed") }
        }.value
        let connected = try await call(.connectionStatus)
        try check(connected.connectionStatus == .connected && connected.agents == nil, "connection status is explicit without a roster")
        let capability = try await call(.capabilities)
        try check(
            capability.capabilities?.context == false && capability.capabilities?.instructions == false,
            "future context and input capabilities are disabled")
        do {
            _ = try LocalAPIServer(profile: profile) { _, _ in LocalAPIResponse() }
            throw E2EFailure(message: "same-profile contender took ownership")
        } catch let error as LocalAPIError {
            try check(error == .endpointBusy, "same-profile contender cannot replace endpoint")
        }
        let deniedProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let denied = try LocalAPIServer(profile: deniedProfile) { _, _ in
            throwawayResponse()
        }
        denied.start()
        defer { denied.stop() }
        let denial = try await Task.detached { try LocalAPIClient.call(LocalAPIRequest(profile: deniedProfile, operation: .listAgents)) }
            .value
        try check(
            denial.error == .accessDisabled && denial.agents == nil && denial.profile == nil,
            "default authorization denies without metadata")
        let gate = E2EAuthorization()
        let revokeProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let revocable = try LocalAPIServer(profile: revokeProfile, authorization: { _ in gate.denial }) { request, instance in
            try? await Task.sleep(for: .milliseconds(150))
            return LocalAPIResponse(
                requestID: request.requestID, profile: revokeProfile, appInstanceID: instance, capturedAt: Date(),
                agents: store.localAPIAgents())
        }
        revocable.start()
        defer { revocable.stop() }
        let inFlight = Task.detached { try LocalAPIClient.call(LocalAPIRequest(profile: revokeProfile, operation: .listAgents)) }
        try await Task.sleep(for: .milliseconds(50))
        gate.revoke()
        let revoked = try await inFlight.value
        try check(revoked.error == .permissionDenied && revoked.agents == nil, "revocation during capture prevents status return")
        let largeProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let row = initial.agents![0]
        let large = try LocalAPIServer(profile: largeProfile, authorization: { _ in nil }) { request, instance in
            LocalAPIResponse(
                requestID: request.requestID, profile: largeProfile, appInstanceID: instance,
                capturedAt: Date(), agents: Array(repeating: row, count: 1024))
        }
        large.start()
        defer { large.stop() }
        let overflow = try await Task.detached { try LocalAPIClient.call(LocalAPIRequest(profile: largeProfile, operation: .listAgents)) }
            .value
        try check(overflow.error == .responseTooLarge && overflow.agents == nil, "response overflow fails without a truncated roster")
        for session in store.groups.flatMap(\.sessions) { store.closeSession(id: session.id) }
        let empty = try await call()
        try check(empty.agents?.isEmpty == true && empty.error == nil, "empty roster is successful")
        server.stop()
        // The ownership lock is released when the listener loop and workers exit.
        try await Task.sleep(for: .milliseconds(100))
        let unavailable = try await call()
        try check(unavailable.error == .appUnavailable, "stopped app is unavailable without profile fallback")
        let restarted = try LocalAPIServer(profile: profile, authorization: { _ in nil }) { request, instance in
            do { _ = try store.localAPIProviders() } catch {
                return LocalAPIResponse(requestID: request.requestID, error: .staleTarget)
            }
            store.bindLocalAPIInstance(instance)
            return LocalAPIResponse(
                requestID: request.requestID, profile: profile, appInstanceID: instance,
                capturedAt: Date(), agents: store.localAPIAgents())
        }
        restarted.start()
        defer { restarted.stop() }
        let restartResponse = try await call()
        try check(restartResponse.appInstanceID != initial.appInstanceID, "endpoint restart has a fresh app-instance identity")
        let restored = SessionStore(groups: [SessionGroup(name: "E2E", sessions: [workspace])])
        store.replaceState(restoring: restored.snapshot())
        let reopened = try await call()
        try check(
            reopened.agents?.first(where: { $0.paneID == first.id })?.targetVersion != original,
            "closed and restored pane cannot resurrect a target")
        let duplicateWorkspace = TerminalSession(title: "Duplicate", workingDirectory: "/tmp", layout: .pane(first))
        let duplicateStore = SessionStore(groups: [SessionGroup(name: "Duplicates", sessions: [workspace, duplicateWorkspace])])
        store = duplicateStore
        let duplicate = try await call()
        try check(duplicate.error == .staleTarget && duplicate.agents == nil, "duplicate pane IDs fail without a crash or ambiguous roster")
        store = restored
        let afterDuplicate = try await call()
        try check(afterDuplicate.error == nil && afterDuplicate.agents?.count == 2, "valid roster recovers after duplicate pane rejection")
        let unsafeProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let unsafe = try LocalAPIEndpoint(profile: unsafeProfile, create: true)
        let sentinel = artifact.appendingPathComponent("symlink-sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(atPath: unsafe.socketPath, withDestinationPath: sentinel.path)
        do {
            _ = try LocalAPIServer(profile: unsafeProfile) { _, _ in LocalAPIResponse() }
            throw E2EFailure(message: "symlink socket was accepted")
        } catch let error as LocalAPIError {
            try check(error == .insecureEndpoint, "symlink socket is refused")
        }
        try check(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged", "symlink refusal preserves the target file")
        guard unlink(unsafe.socketPath) == 0 else { throw E2EFailure(message: "Could not remove E2E socket symlink") }
        let recovered = try LocalAPIServer(profile: unsafeProfile, authorization: { _ in nil }) { request, instance in
            LocalAPIResponse(
                requestID: request.requestID, profile: unsafeProfile, appInstanceID: instance,
                capturedAt: Date(), connectionStatus: .connected)
        }
        recovered.start()
        defer { recovered.stop() }
        let recoveredResponse = try await Task.detached {
            try LocalAPIClient.call(LocalAPIRequest(profile: unsafeProfile, operation: .connectionStatus))
        }.value
        try check(recoveredResponse.connectionStatus == .connected, "failed startup releases ownership for same-process retry")
        let report: [String: Any] = [
            "kind": "socket/store/helper E2E with injected lifecycle fixtures", "profile": profile, "checks": checks,
            "realAgentNativeProof": "separate artifact required",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: artifact.appendingPathComponent("report.json"))
    }

    static func throwawayResponse() -> LocalAPIResponse { LocalAPIResponse(error: .transportFailure) }
}

private final class E2EAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var denial: LocalAPIError? { lock.withLock { enabled ? nil : .permissionDenied } }
    func revoke() { lock.withLock { enabled = false } }
}
