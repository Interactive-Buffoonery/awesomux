import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import AwesoMuxTestSupport
import Foundation

extension LocalAPIE2E {
    @MainActor static func runAttentionScenarios(
        helper: String, artifact: URL, useKeychainHelper: Bool = true
    ) async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            checks.append(name)
            print("PASS: \(name)")
        }
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let first = TerminalPane(title: "First", workingDirectory: "/tmp/shared", agentKind: .codex, executionPlan: .local)
        let second = TerminalPane(title: "Second", workingDirectory: "/tmp/shared", agentKind: .codex, executionPlan: .local)
        let sibling = TerminalPane(title: "Shell", workingDirectory: "/tmp/shared", executionPlan: .local)
        let firstWorkspace = TerminalSession(
            title: "First workspace", workingDirectory: "/tmp/shared",
            layout: .split(TerminalSplit(orientation: .horizontal, first: .pane(first), second: .pane(sibling)))
        )
        let secondWorkspace = TerminalSession(title: "Second workspace", workingDirectory: "/tmp/shared", layout: .pane(second))
        let store = SessionStore(groups: [SessionGroup(name: "Attention E2E", sessions: [firstWorkspace, secondWorkspace])])
        let access = LocalAPIAccessStore(profile: profile, supportDirectoryURL: artifact.appending(path: "attention-access-\(profile)"))
        defer { access.relinquishAuthority() }
        let incarnations = [first.id: "fixture:1:100", second.id: "fixture:2:200"]
        var beforeReturn: (() throws -> Void)?
        func startSession(_ paneID: UUID, _ sessionID: String) {
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: .codex, executionState: .thinking, phase: .sessionStart,
                    eventID: UUID().uuidString, providerSessionID: sessionID, timestamp: Date()
                ), to: store.sessionIDContainingPane(paneID)!, paneID: paneID
            )
        }
        startSession(first.id, "first-session")
        startSession(second.id, "second-session")
        func makeServer() throws -> LocalAPIServer {
            let result = try LocalAPIServer(profile: profile, authorization: access.runtimeAuthority.provider) { request, instance, lease in
                store.bindLocalAPIInstance(instance)
                do {
                    let agents = store.localAPIAgents(processIncarnations: incarnations).filter {
                        lease.statusScope.allows(paneID: $0.paneID, workspaceID: $0.workspaceID, targetVersion: $0.targetVersion)
                    }
                    let page =
                        request.operation == LocalAPIOperation.attentionEvents.rawValue
                        ? try store.localAPIAttentionEvents(
                            cursor: request.cursor, limit: request.limit ?? 0, lease: lease, processIncarnations: incarnations
                        ) : nil
                    try beforeReturn?()
                    return LocalAPIResponse(
                        requestID: request.requestID, profile: profile, appInstanceID: instance, capturedAt: Date(),
                        capabilities: request.operation == LocalAPIOperation.capabilities.rawValue ? LocalAPICapabilities() : nil,
                        agents: request.operation == LocalAPIOperation.listAgents.rawValue ? agents : nil, attentionEvents: page
                    )
                } catch {
                    return LocalAPIResponse(requestID: request.requestID, error: error as? LocalAPIError ?? .transportFailure)
                }
            }
            store.bindLocalAPIInstance(result.instanceID)
            _ = store.localAPIAgents(processIncarnations: incarnations)
            result.start()
            return result
        }
        var server = try makeServer()
        defer { server.stop() }
        var registrations: [LocalAPIPendingRegistration] = []
        func register(_ label: String, _ scope: LocalAPITargetScope) async throws -> LocalAPIPendingRegistration {
            let pending = try access.prepareRegistration(label: label, statusScope: scope)
            if useKeychainHelper {
                try await storeCredential(
                    helper: helper, profile: profile, connectionID: pending.connection.id, credential: pending.credential)
            }
            try access.activateRegistration(pending)
            registrations.append(pending)
            return pending
        }
        defer {
            if useKeychainHelper {
                for pending in registrations {
                    try? deleteCredential(helper: helper, profile: profile, connectionID: pending.connection.id)
                }
            }
        }
        let dot = try await register("Dot fixture", .persistentWorkspaces([firstWorkspace.id]))
        let other = try await register("Second client fixture", .persistentPanes([first.id]))
        func call(
            _ client: LocalAPIPendingRegistration, cursor: String? = nil, limit: Int = 100,
            operation: LocalAPIOperation = .attentionEvents, extra: [String] = []
        ) async throws -> LocalAPIResponse {
            try await Task.detached {
                if !useKeychainHelper && extra.isEmpty {
                    let request = LocalAPIRequest(
                        profile: profile, operation: operation, connectionID: client.connection.id,
                        credential: LocalAPICredential.encode(client.credential),
                        limit: operation == .attentionEvents ? limit : nil, cursor: cursor
                    )
                    return try LocalAPIClient.call(request)
                }
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: helper)
                var arguments = ["--profile", profile, "--credential-handle", client.connection.id.uuidString, operation.rawValue]
                if operation == .attentionEvents {
                    arguments += ["--limit", String(limit)]
                    if let cursor { arguments += ["--cursor", cursor] }
                }
                arguments += extra
                process.arguments = arguments
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                try process.waitUntilExitEventually()
                return try LocalAPIContract.decoder().decode(LocalAPIResponse.self, from: data)
            }.value
        }
        func page(_ response: LocalAPIResponse) throws -> LocalAPIAttentionPage {
            guard response.error == nil, let page = response.attentionEvents else {
                throw E2EFailure(message: "Expected attention page, got \(response.error?.rawValue ?? "no page")")
            }
            return page
        }
        func latestPage(_ client: LocalAPIPendingRegistration) async throws -> LocalAPIAttentionPage {
            var latest = try page(try await call(client))
            while latest.hasMore {
                latest = try page(try await call(client, cursor: latest.nextCursor))
            }
            return latest
        }
        func attention(_ paneID: UUID, _ raised: Bool) {
            store.updatePermissionPromptAttention(
                sessionID: store.sessionIDContainingPane(paneID)!, paneID: paneID,
                countDelta: raised ? 1 : 0, hasPending: raised
            )
        }
        let disabled = try await call(dot)
        try check(disabled.error == .accessDisabled && disabled.attentionEvents == nil, "attention is denied while global access is off")
        try access.setGloballyEnabled(true)
        let capability = try await call(dot, operation: .capabilities)
        try check(
            capability.capabilities?.attentionEvents == true && capability.capabilities?.monitoring == false
                && capability.capabilities?.maximumAttentionEvents == 512,
            "capabilities advertise bounded attention reads without monitoring"
        )
        let baseline = try page(try await call(dot))
        let otherBaseline = try page(try await call(other))
        try check(baseline.events.isEmpty && baseline.cursorStatus == .initial, "first attention check starts with retained history")
        attention(second.id, true)
        attention(second.id, false)
        attention(first.id, true)
        attention(first.id, true)
        let selected = store.selectedSessionID
        let unread = store.unreadNotificationTotal
        let raised = try page(try await call(dot, cursor: baseline.nextCursor))
        try check(raised.events.count == 1 && raised.events[0].change == .raised, "repeated attention state emits one raised record")
        try check(
            raised.events[0].paneID == first.id && raised.events[0].providerSessionID == "first-session",
            "event preserves the exact pane and provider session identity"
        )
        try check(
            store.selectedSessionID == selected && store.unreadNotificationTotal == unread
                && store.session(id: firstWorkspace.id)?.layout.pane(id: first.id)?.attentionReason == .permissionPrompt,
            "attention reads preserve selection unread and native acknowledgment"
        )
        attention(first.id, false)
        let resolved = try page(try await call(dot, cursor: raised.nextCursor))
        try check(
            resolved.events.count == 1 && resolved.events[0].change == .resolved
                && resolved.events[0].attentionID == raised.events[0].attentionID && resolved.events[0].resolvedAt != nil,
            "resolution after a previous read has a correlated attention ID and time"
        )
        let betweenChecks = try page(try await call(other, cursor: otherBaseline.nextCursor))
        try check(
            betweenChecks.events.map(\.change) == [.raised, .resolved]
                && betweenChecks.events.map(\.id) == raised.events.map(\.id) + resolved.events.map(\.id),
            "two clients independently see an alert that resolves between checks"
        )
        try check(
            betweenChecks.events.allSatisfy { $0.paneID == first.id }, "persistent pane and workspace scopes exclude unrelated history")
        let firstPage = try page(try await call(dot, cursor: baseline.nextCursor, limit: 1))
        let secondPage = try page(try await call(dot, cursor: firstPage.nextCursor, limit: 1))
        try check(
            firstPage.hasMore && !secondPage.hasMore && firstPage.events[0].id == raised.events[0].id
                && secondPage.events[0].id == resolved.events[0].id,
            "pagination skips hidden events without skipping authorized resolution"
        )
        let empty = try page(try await call(dot, cursor: secondPage.nextCursor))
        try check(empty.events.isEmpty && !empty.hasMore, "a consumed cursor does not replay events")
        let foreign = try await call(other, cursor: secondPage.nextCursor)
        try check(foreign.error == .invalidCursor && foreign.attentionEvents == nil, "a cursor cannot transfer between connections")
        let invalid = try await call(dot, cursor: "invalid")
        try check(invalid.error == .invalidCursor && invalid.attentionEvents == nil, "malformed cursor fails explicitly")
        var altered = secondPage.nextCursor
        let replacementIndex = altered.index(altered.startIndex, offsetBy: 45)
        altered.replaceSubrange(replacementIndex...replacementIndex, with: altered[replacementIndex] == "A" ? "B" : "A")
        let tampered = try await call(dot, cursor: altered)
        try check(tampered.error == .invalidCursor && tampered.attentionEvents == nil, "altered cursor fails authentication")
        try check(try await call(dot, limit: 0).error == .invalidRequest, "zero page size is rejected")
        try check(
            try await call(dot, extra: ["--source", "transcript"]).error == .invalidRequest,
            "attention helper rejects context-only flags before loading credentials"
        )
        let wireInvalid = try await Task.detached {
            try LocalAPIClient.call(
                LocalAPIRequest(
                    profile: profile, operation: .attentionEvents, connectionID: dot.connection.id,
                    credential: LocalAPICredential.encode(dot.credential), paneID: first.id, limit: 1
                ))
        }.value
        try check(wireInvalid.error == .invalidRequest, "attention wire request rejects context selectors")
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex, executionState: .waiting, phase: .stop,
                eventID: UUID().uuidString, providerSessionID: "first-session", timestamp: Date()
            ), to: firstWorkspace.id, paneID: first.id
        )
        let waiting = try page(try await call(dot, cursor: empty.nextCursor))
        try check(waiting.events.last?.reason == "waitingForInput", "native waiting state produces an alert without an attention overlay")
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex, executionState: .thinking, phase: .promptSubmit,
                eventID: UUID().uuidString, providerSessionID: "first-session", timestamp: Date()
            ), to: firstWorkspace.id, paneID: first.id
        )
        let resumed = try page(try await call(dot, cursor: waiting.nextCursor))
        try check(
            resumed.events.last?.change == .resolved && resumed.events.last?.attentionID == waiting.events.last?.attentionID,
            "agent resumption resolves the native waiting alert"
        )
        for _ in 0..<260 {
            attention(first.id, true)
            attention(first.id, false)
        }
        let gap = try page(try await call(dot, cursor: empty.nextCursor))
        try check(
            gap.cursorStatus == .historyGap && gap.currentStateRecoveryRequired && gap.events.isEmpty,
            "retention overflow explicitly requires current-state recovery"
        )
        let history = try page(try await call(dot, limit: Int.max))
        try check(history.events.count == 100 && history.hasMore, "oversized page request clamps to 100 events")
        var all = history.events
        var continuation = history
        while continuation.hasMore {
            continuation = try page(try await call(dot, cursor: continuation.nextCursor))
            all.append(contentsOf: continuation.events)
        }
        try check(all.count == 512 && Set(all.map(\.id)).count == 512, "retained event history is bounded to 512 distinct ordered changes")
        let recoveredRoster = try await call(dot, operation: .listAgents)
        try check(
            recoveredRoster.agents?.count == 1 && recoveredRoster.agents?.first?.paneID == first.id,
            "gap recovery returns only authorized current agents")
        attention(first.id, true)
        let recoveredEvents = try page(try await call(dot, cursor: gap.nextCursor))
        try check(recoveredEvents.events.count == 1, "a fresh recovery cursor resumes with later events")
        attention(first.id, false)
        let version = store.localAPIAgents(processIncarnations: incarnations).first { $0.paneID == first.id }!.targetVersion
        let exact = try await register("Exact fixture", .exactTarget(paneID: first.id, targetVersion: version))
        attention(first.id, true)
        let exactEvents = try await latestPage(exact)
        try check(
            exactEvents.events.last?.change == .raised && exactEvents.events.allSatisfy { $0.targetVersion == version },
            "exact target sees only its incarnation's events")
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex, phase: .sessionEnd, eventID: UUID().uuidString,
                providerSessionID: "first-session", timestamp: Date()
            ), to: firstWorkspace.id, paneID: first.id
        )
        startSession(first.id, "replacement-session")
        let stale = try await call(exact, cursor: exactEvents.nextCursor)
        try check(
            stale.error == .staleTarget && stale.attentionEvents == nil,
            "replaced provider session explicitly expires the exact target's event access"
        )
        let lifecycle = try page(try await call(dot, cursor: recoveredEvents.nextCursor))
        try check(
            lifecycle.events.contains { $0.change == .resolved && $0.providerSessionID == "first-session" },
            "session replacement resolves attention under the original identity")
        attention(first.id, false)
        attention(first.id, true)
        let beforeMove = try await latestPage(dot)
        _ = store.movePaneToNewWorkspace(id: first.id, in: firstWorkspace.id)
        let moved = try page(try await call(dot, cursor: beforeMove.nextCursor))
        try check(
            moved.events.count == 1 && moved.events[0].change == .resolved && moved.events[0].workspaceID == firstWorkspace.id,
            "moving a pane resolves its old workspace alert without exposing the new workspace"
        )
        let movedWorkspaceID = store.sessionIDContainingPane(first.id)!
        let beforeClose = try await latestPage(other)
        store.closeSession(id: movedWorkspaceID)
        let closed = try page(try await call(other, cursor: beforeClose.nextCursor))
        try check(closed.events.last?.change == .resolved, "closing a pane records its final resolution")
        let beforeScopeEdit = try await latestPage(dot)
        try access.updateStatusScope(connectionID: dot.connection.id, statusScope: .persistentWorkspaces([secondWorkspace.id]))
        let edited = try page(try await call(dot, cursor: beforeScopeEdit.nextCursor))
        try check(
            edited.cursorStatus == .accessChanged && edited.events.isEmpty && edited.currentStateRecoveryRequired,
            "grant edits invalidate old cursor positions without returning history")
        attention(second.id, true)
        let secondCurrent = try page(try await call(dot, cursor: edited.nextCursor))
        try check(
            secondCurrent.events.count == 1 && secondCurrent.events[0].paneID == second.id, "new grant scope resumes only its own events")
        beforeReturn = { try access.setGloballyEnabled(false) }
        let interrupted = try await call(dot)
        beforeReturn = nil
        try check(
            interrupted.error == .accessDisabled && interrupted.attentionEvents == nil,
            "global disable during capture prevents event return")
        try access.setGloballyEnabled(true)
        let beforeRestart = try page(try await call(dot))
        server.stop()
        var successor: LocalAPIServer?
        for _ in 0..<100 {
            do {
                successor = try makeServer()
                break
            } catch LocalAPIError.endpointBusy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard let successor else { throw E2EFailure(message: "Attention server could not restart") }
        server = successor
        let restarted = try page(try await call(dot, cursor: beforeRestart.nextCursor))
        try check(
            restarted.cursorStatus == .appRestarted && restarted.events.isEmpty && restarted.currentStateRecoveryRequired,
            "app restart explicitly resets event history and cursor")
        let restartHistory = try page(try await call(dot))
        try check(
            restartHistory.events.count == 1 && restartHistory.events[0].change == .raised,
            "restart seeds only current attention instead of replaying old history")
        beforeReturn = { try access.revoke(connectionID: dot.connection.id) }
        let revoked = try await call(dot)
        beforeReturn = nil
        try check(revoked.error == .permissionDenied && revoked.attentionEvents == nil, "revocation during capture prevents event return")
        let otherStillWorks = try await call(other)
        try check(
            otherStillWorks.error == nil && otherStillWorks.attentionEvents?.events.isEmpty == true,
            "revoking Dot leaves the other connection usable")
        try LocalAPIContract.encoder().encode(LocalAPIResponse(attentionEvents: betweenChecks)).write(
            to: artifact.appending(path: "attention-between-checks.json"))
        try LocalAPIContract.encoder().encode(LocalAPIResponse(attentionEvents: gap)).write(
            to: artifact.appending(path: "attention-gap.json"))
        try JSONSerialization.data(
            withJSONObject: [
                "kind": useKeychainHelper
                    ? "socket/store/helper attention fixture E2E"
                    : "socket/store attention fixture E2E; helper credential path not exercised",
                "providerAndProcessEvidence": "labeled fixtures", "checks": checks,
                "nativeRealAgentAndPhoneAcceptance": "not exercised",
            ], options: [.prettyPrinted, .sortedKeys]
        ).write(to: artifact.appending(path: "attention-report.json"))
        return checks
    }
}
