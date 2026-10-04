import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import AwesoMuxLocalAPICredentials
import AwesoMuxTestSupport
import Foundation

@MainActor
private final class ContextHost {
    let store: SessionStore
    let access: LocalAPIAccessStore
    let home: URL
    var incarnations: [UUID: String]
    var duringRead: (() throws -> Void)?
    var history = "EXPLICIT TERMINAL HISTORY"
    var readCount = 0

    init(store: SessionStore, access: LocalAPIAccessStore, home: URL, paneIDs: [UUID]) {
        self.store = store
        self.access = access
        self.home = home
        incarnations = Dictionary(uniqueKeysWithValues: paneIDs.map { ($0, "fixture-process:\($0)") })
    }

    func sample(_ paneID: UUID) throws -> LocalAPIAgent {
        _ = try store.localAPIProviders()
        guard let agent = store.localAPIAgents(processIncarnations: incarnations, limitedTo: [paneID]).first else {
            throw LocalAPIError.staleTarget
        }
        return agent
    }

    func capture(_ request: LocalAPIRequest, instance: UUID, lease: LocalAPIAuthorizationLease) async -> LocalAPIResponse {
        store.bindLocalAPIInstance(instance)
        guard request.operation == LocalAPIOperation.agentContext.rawValue else {
            return LocalAPIResponse(
                requestID: request.requestID, profile: request.profile, appInstanceID: instance, capturedAt: Date(),
                agents: request.operation == LocalAPIOperation.listAgents.rawValue
                    ? store.localAPIAgents(processIncarnations: incarnations) : nil,
                contextGrant: request.operation == LocalAPIOperation.connectionStatus.rawValue ? lease.contextGrant : nil
            )
        }
        return await LocalAPIContextCapture.response(
            request: request, instanceID: instance, lease: lease, authorization: access.runtimeAuthority.provider,
            sample: { try self.sample(request.paneID!) },
            read: { agent, source, limit in
                self.readCount += 1
                let output: (String, Bool)
                if source == .terminalHistory {
                    guard self.history.utf8.count <= limit else { throw LocalAPIError.contextTooLarge }
                    output = (self.history, false)
                } else {
                    let kind = AgentKind(rawValue: agent.provider)!
                    let plan = self.store.session(id: agent.workspaceID)!.layout.pane(id: agent.paneID)!.executionPlan
                    let home = self.home
                    let rendered = try await Task.detached {
                        try LocalAPIContextReader.read(
                            agentKind: kind, executionPlan: plan, configHome: home,
                            sessionID: agent.providerSessionID, limit: limit, chrome: contextChrome
                        )
                    }.value
                    output = (rendered.text, rendered.isTruncated)
                }
                try self.duringRead?()
                return output
            }
        )
    }
}

private let contextChrome = AgentTranscriptRenderer.Chrome(
    title: "Session transcript 漢字", sessionLabel: "Session",
    truncationNotice: "Earlier content omitted.", emptyWindowNotice: "No renderable turns in this window.",
    oversizeRecordTitle: "Omitted record", oversizeRecordNotice: { "Omitted \($0)." },
    oversizeFragmentNotice: { "Omitted at least \($0)." }, branchUnavailableNotice: "Branch unavailable."
)

extension LocalAPIE2E {
    @MainActor static func runContextScenarios(helper: String, artifact: URL) async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            checks.append(name)
            print("PASS: \(name)")
        }
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let home = artifact.appending(path: "context-fixtures")
        let logs = home.appending(path: "sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString.lowercased()
        let otherSessionID = UUID().uuidString.lowercased()
        let first = TerminalPane(title: "Exact", workingDirectory: "/tmp/shared", agentKind: .codex, executionPlan: .local)
        let second = TerminalPane(title: "Other", workingDirectory: "/tmp/shared", agentKind: .codex, executionPlan: .local)
        let workspace = TerminalSession(
            title: "Shared directory", workingDirectory: "/tmp/shared",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal, first: .pane(first), second: .pane(second)
                )))
        let store = SessionStore(groups: [SessionGroup(name: "Context E2E", sessions: [workspace])])
        func event(_ paneID: UUID, sessionID: String?, source: AgentRuntimeSource = .codex) {
            let workspaceID = store.sessionIDContainingPane(paneID)!
            let priorKind = store.session(id: workspaceID)!.layout.pane(id: paneID)!.agentKind
            let priorSource: AgentRuntimeSource = priorKind == .grok ? .grok : .codex
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: priorSource, phase: .sessionEnd, eventID: UUID().uuidString,
                    providerSessionID: store.agentProviderSessionID(for: paneID), timestamp: Date()
                ), to: workspaceID, paneID: paneID
            )
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: source, executionState: .waiting, phase: .sessionStart,
                    eventID: UUID().uuidString, providerSessionID: sessionID, timestamp: Date()
                ), to: store.sessionIDContainingPane(paneID)!, paneID: paneID)
        }
        event(first.id, sessionID: sessionID)
        event(second.id, sessionID: otherSessionID)
        let file = logs.appending(path: "rollout-exact-\(sessionID).jsonl")
        func transcript(_ marker: String) throws -> Data {
            var line = try JSONSerialization.data(withJSONObject: [
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": marker]
                    ],
                ],
            ])
            line.append(10)
            return line
        }
        let exactData = try transcript("EXACT SESSION 漢字 café")
        try exactData.write(to: file)
        try transcript("UNRELATED NEWEST SESSION").write(to: logs.appending(path: "rollout-newest-\(otherSessionID).jsonl"))
        let access = LocalAPIAccessStore(profile: profile, supportDirectoryURL: home.appending(path: "access"))
        let host = ContextHost(store: store, access: access, home: home, paneIDs: [first.id, second.id])
        let server = try LocalAPIServer(profile: profile, authorization: access.runtimeAuthority.provider) { request, instance, lease in
            await host.capture(request, instance: instance, lease: lease)
        }
        store.bindLocalAPIInstance(server.instanceID)
        server.start()
        defer { server.stop() }
        let registration = try access.prepareRegistration(label: "Context client", statusScope: .persistentWorkspaces([workspace.id]))
        try await storeCredential(
            helper: helper, profile: profile, connectionID: registration.connection.id, credential: registration.credential)
        try access.activateRegistration(registration)
        defer { try? deleteCredential(helper: helper, profile: profile, connectionID: registration.connection.id) }
        let connectionID = registration.connection.id
        func grant(_ allowHistory: Bool = false) throws -> UUID {
            let version = try host.sample(first.id).targetVersion
            try access.updateContextGrant(
                connectionID: connectionID,
                contextGrant: LocalAPIContextGrant(
                    paneID: first.id, targetVersion: version, allowTerminalHistory: allowHistory
                ))
            return version
        }
        func call(
            version: UUID, paneID: UUID = first.id, source: LocalAPIContextSource = .transcript,
            limit: Int = 24 * 1024, operation: LocalAPIOperation = .agentContext
        ) async throws
            -> LocalAPIResponse
        {
            try await Task.detached {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: helper)
                var arguments = ["--profile", profile, "--credential-handle", connectionID.uuidString, operation.rawValue]
                if operation == .agentContext {
                    arguments += [
                        "--pane-id", paneID.uuidString, "--target-version", version.uuidString,
                        "--limit", String(limit), "--source", source.rawValue,
                    ]
                }
                process.arguments = arguments
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                try process.waitUntilExitEventually()
                return try LocalAPIContract.decoder().decode(LocalAPIResponse.self, from: data)
            }.value
        }
        var version = try host.sample(first.id).targetVersion
        try check(try await call(version: version).error == .accessDisabled, "context remains globally disabled after registration")
        try access.setGloballyEnabled(true)
        try check(
            try await call(version: version).error == .permissionDenied && host.readCount == 0,
            "status access grants no context and performs no content read")
        version = try grant()
        let grantStatus = try await call(version: version, operation: .connectionStatus)
        try check(
            grantStatus.contextGrant?.paneID == first.id && grantStatus.contextGrant?.targetVersion == version
                && grantStatus.agents == nil && grantStatus.agentContext == nil,
            "connection status exposes its own context selectors without roster or content")
        let exact = try await call(version: version)
        try check(
            exact.error == nil && exact.agentContext?.content.contains("EXACT SESSION") == true
                && exact.agentContext?.content.contains("UNRELATED") == false,
            "same-directory newest session cannot replace the exact session")
        try check(
            exact.agentContext?.paneID == first.id && exact.agentContext?.providerSessionID == sessionID
                && exact.agentContext?.source == .transcript && exact.agentContext?.untrusted == true
                && exact.agentContext?.byteCount == exact.agentContext?.content.utf8.count,
            "context includes identity source byte count capture time and untrusted label")
        try LocalAPIContract.encoder().encode(exact).write(to: artifact.appending(path: "exact-context.json"))
        try check(
            try await call(version: version, paneID: second.id).error == .permissionDenied, "context grant never broadens to another pane")
        try check(
            try await call(version: version, source: .terminalHistory).error == .permissionDenied,
            "terminal history requires separate consent")
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("held"))
        try check(
            try await call(version: version).error == .contextUnavailable,
            "missing exact transcript never falls back to another session or history")
        try FileManager.default.moveItem(at: file.appendingPathExtension("held"), to: file)
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("held"))
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: logs.appending(path: "rollout-newest-\(otherSessionID).jsonl"))
        try check(try await call(version: version).error == .contextUnavailable, "symlink transcript cannot expose another session")
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("refused-link"))
        try FileManager.default.moveItem(at: file.appendingPathExtension("held"), to: file)
        version = try grant(true)
        let history = try await call(version: version, source: .terminalHistory)
        try check(
            history.agentContext?.source == .terminalHistory && history.agentContext?.content == host.history,
            "explicit separately consented terminal history is labeled")
        try LocalAPIContract.encoder().encode(history).write(to: artifact.appending(path: "history-context.json"))
        try check(
            try await call(version: version, source: .terminalHistory, limit: 1).error == .contextTooLarge,
            "oversized native history has an explicit refusal")
        let headerPrefix = "# Session transcript "
        let unicode = try await call(version: version, limit: headerPrefix.utf8.count + 1)
        try check(
            unicode.agentContext?.content == headerPrefix && unicode.agentContext?.truncated == true,
            "UTF-8 clipping inside a multibyte scalar preserves its boundary and reports truncation")
        try transcript(String(repeating: "漢字 café ", count: 5000)).write(to: file)
        let bounded = try await call(version: version, limit: Int.max)
        try check(
            bounded.agentContext!.byteCount <= 24 * 1024 && bounded.agentContext!.truncated,
            "large transcript and oversized requested limit remain bounded to 24 KiB")
        try exactData.write(to: file)
        host.duringRead = { try access.updateContextGrant(connectionID: connectionID, contextGrant: nil) }
        let revoked = try await call(version: version)
        try check(
            revoked.agentContext == nil && [.permissionDenied, .transportFailure].contains(revoked.error),
            "context revocation during read returns no content")
        host.duringRead = nil
        version = try grant()
        host.duringRead = { host.incarnations[first.id] = "replacement-process" }
        try check(try await call(version: version).error == .staleTarget, "process replacement during read rejects content")
        host.duringRead = nil
        version = try grant()
        host.duringRead = { event(first.id, sessionID: UUID().uuidString.lowercased()) }
        try check(try await call(version: version).error == .staleTarget, "provider session switch during read rejects content")
        host.duringRead = nil
        event(first.id, sessionID: sessionID)
        version = try grant()
        host.duringRead = {
            event(first.id, sessionID: UUID().uuidString.lowercased())
            event(first.id, sessionID: sessionID)
        }
        try check(try await call(version: version).error == .staleTarget, "provider switch away and back cannot resurrect an old target")
        host.duringRead = nil
        version = try grant()
        host.duringRead = { try access.setGloballyEnabled(false) }
        let disabled = try await call(version: version)
        try check(
            disabled.agentContext == nil && [.accessDisabled, .transportFailure].contains(disabled.error),
            "global disable during read returns no content")
        host.duringRead = nil
        try access.setGloballyEnabled(true)
        version = try grant()
        host.incarnations[first.id] = nil
        version = try grant()
        try check(try await call(version: version).error == .processIdentityUnknown, "unknown process identity denies content")
        host.incarnations[first.id] = "fixture-process"
        event(first.id, sessionID: nil)
        version = try grant()
        try check(try await call(version: version).error == .noSessionIdentity, "missing provider session identity has an explicit outcome")
        let localSnapshot = store.snapshot()
        var remotePane = first
        remotePane.executionPlan = .ssh(SSHExecution(target: RemoteTarget(user: "", host: "context-fixture.invalid")!))
        let remoteWorkspace = TerminalSession(id: workspace.id, title: "Remote", workingDirectory: "/tmp/shared", layout: .pane(remotePane))
        store.replaceState(restoring: SessionStore(groups: [SessionGroup(name: "Remote", sessions: [remoteWorkspace])]).snapshot())
        event(first.id, sessionID: sessionID)
        version = try grant()
        let readsBeforeRemote = host.readCount
        try check(
            try await call(version: version).error == .remoteContext && host.readCount == readsBeforeRemote,
            "remote transcript returns an explicit refusal before content I/O")
        store.replaceState(restoring: localSnapshot)
        event(first.id, sessionID: "grok-session", source: .grok)
        version = try grant()
        try check(try await call(version: version).error == .unsupportedProvider, "unsupported provider cannot fall through to Codex")
        event(first.id, sessionID: sessionID)
        version = try grant()
        host.duringRead = { _ = store.movePaneToNewWorkspace(id: first.id, in: workspace.id) }
        try check(try await call(version: version).error == .staleTarget, "moving target to another workspace during read rejects content")
        host.duringRead = nil
        version = try grant()
        let movedWorkspaceID = store.sessionIDContainingPane(first.id)!
        host.duringRead = { store.closeSession(id: movedWorkspaceID) }
        try check(try await call(version: version).error == .staleTarget, "closing target workspace during read rejects content")
        host.duringRead = nil
        try JSONSerialization.data(
            withJSONObject: [
                "kind": "socket/helper exact-context E2E; provider and terminal fixtures",
                "checks": checks, "nativeHistoryProof": "separate native artifact required",
            ], options: [.prettyPrinted, .sortedKeys]
        ).write(to: artifact.appending(path: "context-report.json"))
        return checks
    }
}
