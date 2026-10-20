import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation

extension LocalAPIE2E {
    @MainActor static func runCommandAttentionScenarios(artifact: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            checks.append(name)
            print("PASS: \(name)")
        }
        let shell = TerminalPane(title: "Shell", workingDirectory: "/tmp", executionPlan: .local)
        let agent = TerminalPane(title: "Agent", workingDirectory: "/tmp", agentKind: .codex, executionPlan: .local)
        let workspace = TerminalSession(
            title: "Commands", workingDirectory: "/tmp",
            layout: .split(TerminalSplit(orientation: .horizontal, first: .pane(shell), second: .pane(agent)))
        )
        let store = SessionStore(groups: [SessionGroup(name: "Commands", sessions: [workspace])])
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let access = LocalAPIAccessStore(profile: profile, supportDirectoryURL: artifact.appending(path: "access"))
        defer { access.relinquishAuthority() }
        let client = try access.prepareRegistration(label: "Command fixture", statusScope: .persistentPanes([shell.id]))
        try access.activateRegistration(client)
        let agentClient = try access.prepareRegistration(label: "Agent fixture", statusScope: .persistentPanes([agent.id]))
        try access.activateRegistration(agentClient)
        try access.setGloballyEnabled(true)
        let server = try LocalAPIServer(profile: profile, authorization: access.runtimeAuthority.provider) { request, instance, lease in
            store.bindLocalAPIInstance(instance)
            do {
                let page = try store.localAPIAttentionEvents(cursor: request.cursor, limit: request.limit ?? 100, lease: lease)
                return LocalAPIResponse(
                    requestID: request.requestID, profile: profile, appInstanceID: instance, capturedAt: Date(), attentionEvents: page)
            } catch {
                return LocalAPIResponse(requestID: request.requestID, error: error as? LocalAPIError ?? .transportFailure)
            }
        }
        store.bindLocalAPIInstance(server.instanceID)
        server.start()
        defer { server.stop() }
        func read(_ cursor: String? = nil, using registration: LocalAPIPendingRegistration? = nil) async throws -> LocalAPIResponse {
            let selectedClient = registration ?? client
            return try await Task.detached {
                try LocalAPIClient.call(
                    LocalAPIRequest(
                        profile: profile, operation: .attentionEvents, connectionID: selectedClient.connection.id,
                        credential: LocalAPICredential.encode(selectedClient.credential), limit: 100, cursor: cursor))
            }.value
        }
        func page(_ response: LocalAPIResponse) throws -> LocalAPIAttentionPage {
            guard response.error == nil, let result = response.attentionEvents else {
                throw E2EFailure(message: "Command attention read failed: \(response.error?.rawValue ?? "missing page")")
            }
            return result
        }
        func finish(_ pane: TerminalPane, code: Int16, nanoseconds: UInt64) {
            guard let completion = ShellCommandCompletion(exitCode: code, durationNanoseconds: nanoseconds) else { return }
            store.recordCommandCompletion(
                sessionID: workspace.id, paneID: pane.id, terminalSessionID: pane.terminalSessionID,
                executionPlan: pane.executionPlan, completion: completion)
        }
        let baseline = try page(try await read())
        finish(shell, code: -1, nanoseconds: 40_000_000_000)
        finish(shell, code: 256, nanoseconds: 40_000_000_000)
        finish(shell, code: 0, nanoseconds: 0)
        finish(shell, code: 1, nanoseconds: 1_000_000_000)
        finish(shell, code: 0, nanoseconds: 30_000_000_000)
        try check(
            try page(try await read(baseline.nextCursor)).events.isEmpty,
            "unknown invalid initial and threshold-length completions emit nothing")
        let selected = store.selectedSessionID
        store.updatePermissionPromptAttention(sessionID: workspace.id, paneID: agent.id, countDelta: 1, hasPending: true)
        let unread = store.unreadNotificationTotal
        finish(shell, code: 0, nanoseconds: 30_000_000_001)
        finish(shell, code: 0, nanoseconds: 30_000_000_001)
        finish(shell, code: 7, nanoseconds: 42_500_000_000)
        finish(agent, code: 1, nanoseconds: 40_000_000_000)
        let response = try await read(baseline.nextCursor)
        let completed = try page(response)
        try check(completed.events.count == 3, "each shell command emits one fact and scope excludes the sibling")
        try check(
            completed.events.allSatisfy {
                $0.change == .raised && $0.resolvedAt == nil && $0.paneID == shell.id
                    && $0.workspaceID == workspace.id && $0.provider == AgentKind.shell.rawValue
                    && $0.providerSessionID == nil && $0.targetVersion == completed.events[0].targetVersion
            },
            "command facts preserve shell identity without inventing a resolution")
        try check(
            Set(completed.events.map(\.attentionID)).count == 3
                && completed.events.map(\.reason) == ["commandFinished", "commandFinished", "commandFailed"]
                && completed.events.map(\.exitCode) == [0, 0, 7]
                && completed.events.first?.durationSeconds == 30.000000001
                && completed.events.last?.durationSeconds == 42.5,
            "repeated success and failure retain distinct IDs and exact metadata over the socket")
        let companion = response.companionResponse
        try check(
            companion.attentionEvents?.events.last?.exitCode == 7
                && companion.attentionEvents?.events.last?.durationSeconds == 42.5,
            "Companion adapter preserves command metadata")
        try check(
            store.selectedSessionID == selected && store.unreadNotificationTotal == unread
                && store.session(id: workspace.id)?.layout.pane(id: agent.id)?.attentionReason == .permissionPrompt,
            "command completion preserves selection and unrelated permission attention")
        let beforeRejected = try page(try await read(completed.nextCursor))
        store.recordCommandCompletion(
            sessionID: workspace.id, paneID: shell.id, terminalSessionID: .generate(), executionPlan: .local,
            completion: ShellCommandCompletion(exitCode: 1, durationNanoseconds: 40_000_000_000)!)
        try check(
            try page(try await read(beforeRejected.nextCursor)).events.isEmpty,
            "a completion from a replaced terminal assignment is rejected")
        store.updatePermissionPromptAttention(sessionID: workspace.id, paneID: agent.id, countDelta: 0, hasPending: false)
        let agentEvents = try page(try await read(using: agentClient)).events
        try check(
            agentEvents.map(\.reason) == ["permissionPrompt", "commandFailed", "permissionPrompt"]
                && agentEvents.map(\.change) == [.raised, .raised, .resolved]
                && agentEvents[0].attentionID == agentEvents[2].attentionID
                && agentEvents[1].attentionID != agentEvents[0].attentionID
                && agentEvents[0].exitCode == nil && agentEvents[0].durationSeconds == nil,
            "permission resolution retains its own ID while same-pane command fact stays independent")
        try check(
            try page(try await read(beforeRejected.nextCursor)).events.isEmpty,
            "state reconciliation does not resolve or replay completed command facts")
        for _ in 0..<520 { finish(shell, code: 1, nanoseconds: 40_000_000_000) }
        let gap = try page(try await read(completed.nextCursor))
        try check(
            gap.cursorStatus == .historyGap && gap.currentStateRecoveryRequired && gap.events.isEmpty,
            "command traffic uses bounded journal and existing gap recovery")
        var retained = try page(try await read())
        var count = retained.events.count
        while retained.hasMore {
            retained = try page(try await read(retained.nextCursor))
            count += retained.events.count
        }
        try check(count == 512, "command history retains at most 512 changes")
        try JSONEncoder().encode(checks).write(to: artifact.appending(path: "command-attention.json"))
        return checks
    }
}
