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
                let page = try store.localAPIAttentionEvents(
                    cursor: request.cursor, limit: request.limit ?? 100, lease: lease,
                    includeCommandEvents: request.includeCommandEvents ?? false)
                return LocalAPIResponse(
                    requestID: request.requestID, profile: profile, appInstanceID: instance, capturedAt: Date(), attentionEvents: page)
            } catch {
                return LocalAPIResponse(requestID: request.requestID, error: error as? LocalAPIError ?? .transportFailure)
            }
        }
        store.bindLocalAPIInstance(server.instanceID)
        server.start()
        defer { server.stop() }
        func read(
            _ cursor: String? = nil, using registration: LocalAPIPendingRegistration? = nil,
            includeCommandEvents: Bool? = true, limit: Int = 100,
            operation: LocalAPIOperation = .attentionEvents
        ) async throws -> LocalAPIResponse {
            let selectedClient = registration ?? client
            return try await Task.detached {
                try LocalAPIClient.call(
                    LocalAPIRequest(
                        profile: profile, operation: operation, connectionID: selectedClient.connection.id,
                        credential: LocalAPICredential.encode(selectedClient.credential),
                        limit: operation == .attentionEvents ? limit : nil, cursor: cursor,
                        includeCommandEvents: includeCommandEvents))
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
        let decodeFixture = LocalAPIRequest(profile: profile, operation: .attentionEvents, limit: 1)
        guard
            var decodeObject = try JSONSerialization.jsonObject(
                with: LocalAPIContract.encoder().encode(decodeFixture)) as? [String: Any]
        else { throw E2EFailure(message: "Command request fixture must be an object") }
        let invalidValues: [Any] = [1, "true", [String](), ["enabled": true]]
        for invalidValue in invalidValues {
            decodeObject["includeCommandEvents"] = invalidValue
            let bytes = try JSONSerialization.data(withJSONObject: decodeObject)
            try check(
                (try? LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: bytes)) == nil,
                "command opt-in decoder rejects non-boolean \(String(describing: invalidValue))")
        }
        decodeObject["includeCommandEvents"] = NSNull()
        let nullRequest = try LocalAPIContract.decoder().decode(
            LocalAPIRequest.self, from: JSONSerialization.data(withJSONObject: decodeObject))
        try check(nullRequest.includeCommandEvents == nil, "null command opt-in follows optional request field conventions")
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
        let omitted = try page(try await read(using: agentClient, includeCommandEvents: nil, limit: 1))
        let excluded = try page(try await read(using: agentClient, includeCommandEvents: false, limit: 1))
        try check(
            omitted.events.map(\.reason) == ["permissionPrompt"] && !omitted.hasMore
                && excluded.events.map(\.id) == omitted.events.map(\.id) && !excluded.hasMore,
            "omitted and false opt-in preserve state alerts and filter command facts before pagination")
        let fromOmitted = try page(try await read(omitted.nextCursor, using: agentClient, includeCommandEvents: false))
        let fromFalse = try page(try await read(excluded.nextCursor, using: agentClient, includeCommandEvents: nil))
        try check(
            fromOmitted.events.isEmpty && fromFalse.events.isEmpty,
            "omission and false share the same cursor mode")
        for mode in [omitted.nextCursor, excluded.nextCursor] {
            try check(
                try await read(mode, using: agentClient).error == .invalidCursor,
                "state-only cursor rejects command-inclusive mode")
        }
        try check(
            try await read(baseline.nextCursor, includeCommandEvents: false).error == .invalidCursor,
            "command-inclusive cursor rejects state-only mode")
        for operation in [LocalAPIOperation.capabilities, .connectionStatus, .listAgents, .agentContext] {
            for flag in [false, true] {
                try check(
                    try await read(includeCommandEvents: flag, operation: operation).error == .invalidRequest,
                    "command opt-in is rejected for \(operation.rawValue) even when \(flag)")
            }
        }
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
        let agentPage = try page(try await read(using: agentClient))
        let agentEvents = agentPage.events
        try check(
            try await read(agentPage.nextCursor, using: client).error == .invalidCursor,
            "command-inclusive cursor retains connection ownership")
        let agentState = try page(try await read(using: agentClient, includeCommandEvents: nil, limit: 1))
        let agentStateEnd = try page(
            try await read(agentState.nextCursor, using: agentClient, includeCommandEvents: false, limit: 1))
        try check(
            agentState.events.map(\.change) == [.raised] && agentState.hasMore
                && agentStateEnd.events.map(\.change) == [.resolved] && !agentStateEnd.hasMore
                && agentStateEnd.events.first?.attentionID == agentState.events.first?.attentionID,
            "state-only pagination retains both state transitions around excluded command facts")
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
        let stateOnly = try page(try await read(includeCommandEvents: nil, limit: 1))
        try check(stateOnly.events.isEmpty && !stateOnly.hasMore, "retained command-only history leaves the default feed empty")
        var retained = try page(try await read(limit: 1000))
        try check(retained.events.count == 100 && retained.hasMore, "command-inclusive pages respect the maximum page size")
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

extension LocalAPIE2E {
    // Failure model: foreground-only activity, duplicate returns, late request
    // completions, and preference suppression must not change away membership.
    @MainActor static func runWhileAwayScenarios(artifact: URL) throws {
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            print("PASS: \(name)")
            checks.append(name)
        }
        let pane = TerminalPane(title: "Away shell", workingDirectory: "/tmp", executionPlan: .local)
        let workspace = TerminalSession(title: "Away workspace", workingDirectory: "/tmp", layout: .pane(pane))
        let store = SessionStore(groups: [SessionGroup(name: "Away", sessions: [workspace])])
        store.bindLocalAPIInstance(UUID())
        store.companionAlertIsSuppressed = { _ in true }
        func finish() {
            store.recordCommandCompletion(
                sessionID: workspace.id, paneID: pane.id, terminalSessionID: pane.terminalSessionID,
                executionPlan: pane.executionPlan,
                completion: ShellCommandCompletion(exitCode: 1, durationNanoseconds: 40_000_000_000)!)
        }
        store.recordAuthenticatedCompanionActivity()
        store.beginCompanionAwayPeriod()
        finish()
        store.endCompanionAwayPeriod()
        store.presentWhileAwaySummaryIfReady()
        try check(store.whileAwaySummary == nil, "activity before departure does not qualify")
        store.beginCompanionAwayPeriod()
        store.beginCompanionAwayPeriod()
        finish()
        store.recordAuthenticatedCompanionActivity()
        store.endCompanionAwayPeriod()
        finish()
        try check(store.whileAwaySummary == nil, "return waits for app activation")
        store.presentWhileAwaySummaryIfReady()
        try check(
            store.whileAwaySummary?.events.count == 1, "all-events summary ignores device suppression and excludes post-return events")
        let identity = store.whileAwaySummary?.events.first?.id
        store.endCompanionAwayPeriod()
        store.presentWhileAwaySummaryIfReady()
        try check(store.whileAwaySummary?.events.first?.id == identity, "duplicate return preserves identity")
        store.beginCompanionAwayPeriod()
        finish()
        store.recordAuthenticatedCompanionActivity()
        store.endCompanionAwayPeriod()
        store.presentWhileAwaySummaryIfReady()
        try check(store.whileAwaySummary?.events.count == 2, "multiple eligible intervals accumulate without local events")
        store.dismissWhileAwaySummary()
        store.beginCompanionAwayPeriod()
        store.recordAuthenticatedCompanionActivity()
        store.endCompanionAwayPeriod()
        store.presentWhileAwaySummaryIfReady()
        try check(store.whileAwaySummary == nil, "empty eligible interval has no banner")
        store.beginCompanionAwayPeriod()
        store.recordAuthenticatedCompanionActivity()
        for _ in 0..<513 { finish() }
        store.endCompanionAwayPeriod()
        store.presentWhileAwaySummaryIfReady()
        try check(
            store.whileAwaySummary?.events.count == 512 && store.whileAwaySummary?.olderActivityUnavailable == true,
            "overflow retains bounded history with explicit gap")
        store.dismissWhileAwaySummary()
        store.beginCompanionAwayPeriod()
        finish()
        store.endCompanionAwayPeriod()
        store.recordAuthenticatedCompanionActivity()
        store.presentWhileAwaySummaryIfReady()
        try check(store.whileAwaySummary == nil, "authentication after return cannot qualify past interval")
        let agent = TerminalPane(title: "Away agent", workingDirectory: "/tmp", agentKind: .codex, executionPlan: .local)
        let agentWorkspace = TerminalSession(title: "Agent workspace", workingDirectory: "/tmp", layout: .pane(agent))
        let agentStore = SessionStore(groups: [SessionGroup(name: "Agent", sessions: [agentWorkspace])])
        agentStore.bindLocalAPIInstance(UUID())
        agentStore.beginCompanionAwayPeriod()
        agentStore.recordAuthenticatedCompanionActivity()
        agentStore.updatePermissionPromptAttention(sessionID: agentWorkspace.id, paneID: agent.id, countDelta: 1, hasPending: true)
        agentStore.updatePermissionPromptAttention(sessionID: agentWorkspace.id, paneID: agent.id, countDelta: -1, hasPending: false)
        agentStore.endCompanionAwayPeriod()
        agentStore.presentWhileAwaySummaryIfReady()
        let changes = agentStore.whileAwaySummary?.events ?? []
        try check(
            changes.count == 2 && changes.first?.attentionID == changes.last?.attentionID && changes.last?.change == .resolved,
            "resolved attention retains stable identity and resolution")
        agentStore.closeSession(id: agentWorkspace.id, captureRecentlyClosed: false)
        try check(
            agentStore.whileAwaySummary?.events.count == 2 && agentStore.session(id: agentWorkspace.id) == nil,
            "deleted workspace and pane activity remain available by identity")
        agentStore.bindLocalAPIInstance(UUID())
        try check(agentStore.whileAwaySummary == nil, "journal replacement clears presentation")
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact.appending(path: "while-away.json"))
    }
}
