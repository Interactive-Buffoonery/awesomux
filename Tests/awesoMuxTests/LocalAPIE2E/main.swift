import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import AwesoMuxLocalAPICredentials
import AwesoMuxTestSupport
import Darwin
import Foundation

struct E2EFailure: Error { let message: String }

@main
struct LocalAPIE2E {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--crash-host" {
            let host = try LocalAPIServer(profile: args[1]) { _, _, _ in LocalAPIResponse() }
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
        let fixtureConnectionID = UUID()
        try await storeCredential(
            helper: helper,
            profile: profile,
            connectionID: fixtureConnectionID,
            credential: try LocalAPICredentialKeychain.generate()
        )
        defer {
            try? deleteCredential(helper: helper, profile: profile, connectionID: fixtureConnectionID)
        }
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
        let server = try LocalAPIServer(
            profile: profile,
            authorization: .unrestricted(scope: .persistentWorkspaces([workspace.id]))
        ) { request, instance, _ in
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
                process.arguments = [
                    "--profile", profile,
                    "--credential-handle", fixtureConnectionID.uuidString.lowercased(),
                    operation.rawValue,
                ]
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
        let beforeRestart = restoredProvider.agents!.first { $0.paneID == first.id }!.targetVersion
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
            _ = try LocalAPIServer(profile: profile) { _, _, _ in LocalAPIResponse() }
            throw E2EFailure(message: "same-profile contender took ownership")
        } catch let error as LocalAPIError {
            try check(error == .endpointBusy, "same-profile contender cannot replace endpoint")
        }
        let deniedProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let denied = try LocalAPIServer(profile: deniedProfile) { _, _, _ in
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
        let revocable = try LocalAPIServer(profile: revokeProfile, authorization: gate.provider) { request, instance, _ in
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
        let large = try LocalAPIServer(
            profile: largeProfile,
            authorization: .unrestricted(scope: .persistentWorkspaces([workspace.id]))
        ) { request, instance, _ in
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
        let restarted = try LocalAPIServer(
            profile: profile,
            authorization: .unrestricted(scope: .persistentWorkspaces([workspace.id]))
        ) { request, instance, _ in
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
            _ = try LocalAPIServer(profile: unsafeProfile) { _, _, _ in LocalAPIResponse() }
            throw E2EFailure(message: "symlink socket was accepted")
        } catch let error as LocalAPIError {
            try check(error == .insecureEndpoint, "symlink socket is refused")
        }
        try check(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged", "symlink refusal preserves the target file")
        guard unlink(unsafe.socketPath) == 0 else { throw E2EFailure(message: "Could not remove E2E socket symlink") }
        let recovered = try LocalAPIServer(
            profile: unsafeProfile,
            authorization: .unrestricted(scope: .persistentWorkspaces([workspace.id]))
        ) { request, instance, _ in
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
        checks.append(
            contentsOf: try await runScopedProjectionGrantScenarios(
                helper: helper,
                artifact: artifact,
                workspace: workspace,
                firstPaneID: first.id,
                secondPaneID: second.id
            )
        )
        checks.append(contentsOf: try await runGrantScenarios(helper: helper, artifact: artifact, agents: store.localAPIAgents()))
        let report: [String: Any] = [
            "kind": "socket/store/helper and profile-scoped connection grant E2E", "profile": profile, "checks": checks,
            "realAgentNativeProof": "separate artifact required",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: artifact.appendingPathComponent("report.json"))
    }

    static func throwawayResponse() -> LocalAPIResponse { LocalAPIResponse(error: .transportFailure) }

    static func storeCredential(
        helper: String,
        profile: String,
        connectionID: UUID,
        credential: Data
    ) async throws {
        try await Task.detached {
            let process = Process()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [
                "credential", "store",
                "--profile", profile,
                "--credential-handle", connectionID.uuidString.lowercased(),
            ]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: credential)
            try input.fileHandleForWriting.close()
            try process.waitUntilExitEventually()
            guard process.terminationStatus == 0 else {
                throw E2EFailure(message: "helper could not store a Keychain credential")
            }
        }.value
    }

    static func deleteCredential(helper: String, profile: String, connectionID: UUID) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [
            "credential", "delete",
            "--profile", profile,
            "--credential-handle", connectionID.uuidString.lowercased(),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try process.waitUntilExitEventually()
        guard process.terminationStatus == 0 else {
            throw E2EFailure(message: "helper could not delete a Keychain credential")
        }
    }

    @MainActor
    static func runScopedProjectionGrantScenarios(
        helper: String,
        artifact: URL,
        workspace: TerminalSession,
        firstPaneID: UUID,
        secondPaneID: UUID
    ) async throws -> [String] {
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let supportDirectory = artifact.appending(path: "projection-grant-profile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let store = SessionStore(groups: [SessionGroup(name: "Projection grants", sessions: [workspace])])
        let incarnations = [
            firstPaneID: "local:303:3003",
            secondPaneID: "local:404:4004",
        ]
        let reviewed = store.localAPIAgents(processIncarnations: incarnations)
        guard
            let firstAgent = reviewed.first(where: { $0.paneID == firstPaneID }),
            let secondAgent = reviewed.first(where: { $0.paneID == secondPaneID })
        else { throw E2EFailure(message: "projection grant scenarios need both agents") }

        let accessStore = LocalAPIAccessStore(profile: profile, supportDirectoryURL: supportDirectory)
        defer { accessStore.relinquishAuthority() }
        let firstPending = try accessStore.prepareRegistration(
            label: "Exact client A",
            statusScope: .exactTarget(paneID: firstPaneID, targetVersion: firstAgent.targetVersion)
        )
        let secondPending = try accessStore.prepareRegistration(
            label: "Exact client B",
            statusScope: .exactTarget(paneID: secondPaneID, targetVersion: secondAgent.targetVersion)
        )
        let registrations = [firstPending, secondPending]
        var storedCredentialIDs: [UUID] = []
        defer {
            for connectionID in storedCredentialIDs {
                try? deleteCredential(helper: helper, profile: profile, connectionID: connectionID)
            }
        }
        for pending in registrations {
            try await storeCredential(
                helper: helper,
                profile: profile,
                connectionID: pending.connection.id,
                credential: pending.credential
            )
            storedCredentialIDs.append(pending.connection.id)
            try accessStore.activateRegistration(pending)
        }
        try accessStore.setGloballyEnabled(true)

        let server = try LocalAPIServer(
            profile: profile,
            authorization: accessStore.runtimeAuthority.provider
        ) { request, instance, lease in
            guard case .exactTarget(let paneID, _) = lease.statusScope,
                let incarnation = incarnations[paneID]
            else {
                return LocalAPIResponse(requestID: request.requestID, error: .staleTarget)
            }
            let agents = store.localAPIAgents(
                processIncarnations: [paneID: incarnation],
                limitedTo: [paneID]
            ).filter {
                lease.statusScope.allows(
                    paneID: $0.paneID,
                    workspaceID: $0.workspaceID,
                    targetVersion: $0.targetVersion
                )
            }
            return LocalAPIResponse(
                requestID: request.requestID,
                profile: profile,
                appInstanceID: instance,
                capturedAt: Date(),
                agents: agents
            )
        }
        accessStore.setInvalidationHandler { [weak server] connectionID in
            server?.invalidate(connectionID: connectionID)
        }
        server.start()
        defer { server.stop() }

        let first = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        let second = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        let firstAgain = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        let secondAgain = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        let passed =
            first.agents?.map(\.targetVersion) == [firstAgent.targetVersion]
            && second.agents?.map(\.targetVersion) == [secondAgent.targetVersion]
            && firstAgain.agents?.map(\.targetVersion) == [firstAgent.targetVersion]
            && secondAgain.agents?.map(\.targetVersion) == [secondAgent.targetVersion]
        guard passed else {
            throw E2EFailure(message: "credentialed disjoint exact grants preserve both target versions")
        }
        let projectionCheck = "credentialed disjoint exact grants preserve both target versions"
        print("PASS: \(projectionCheck)")

        let credentialNeedles = registrations.flatMap { pending -> [Data] in
            let encoded = LocalAPICredential.encode(pending.credential) ?? ""
            return [pending.credential, Data(encoded.utf8)]
        }
        let artifactFiles =
            (FileManager.default.enumerator(at: supportDirectory, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let artifactData = try artifactFiles.filter(\.isFileURL).reduce(into: Data()) { aggregate, url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return
            }
            aggregate.append(try Data(contentsOf: url))
        }
        guard credentialNeedles.allSatisfy({ !artifactData.contains($0) }) else {
            throw E2EFailure(message: "scoped projection artifacts contain no credentials")
        }
        let artifactCheck = "scoped projection artifacts contain no credentials"
        print("PASS: \(artifactCheck)")
        return [projectionCheck, artifactCheck]
    }

    @MainActor
    static func runGrantScenarios(
        helper: String,
        artifact: URL,
        agents: [LocalAPIAgent]
    ) async throws -> [String] {
        guard agents.count >= 2 else { throw E2EFailure(message: "grant scenarios need two agents") }
        let profile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let supportDirectory = artifact.appending(path: "grant-profile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw E2EFailure(message: name) }
            checks.append(name)
            print("PASS: \(name)")
        }

        let roster = E2EAgentRoster(agents)
        let captureGate = E2ECaptureGate()
        var accessStore: LocalAPIAccessStore? = LocalAPIAccessStore(
            profile: profile,
            supportDirectoryURL: supportDirectory
        )
        guard let initialStore = accessStore else { throw E2EFailure(message: "access store unavailable") }
        try check(initialStore.ownsAuthority && initialStore.loadFailure == nil, "isolated grant store owns its profile authority")
        try check(
            LocalAPITargetScope.currentTarget(
                activePaneID: UUID(),
                targetVersions: [agents[0].paneID: agents[0].targetVersion]
            ) == nil,
            "ineligible current target does not select another pane"
        )

        let firstPending = try initialStore.prepareRegistration(
            label: "Client A",
            statusScope: .persistentPanes([agents[0].paneID])
        )
        let secondPending = try initialStore.prepareRegistration(
            label: "Client B",
            statusScope: .persistentWorkspaces([agents[0].workspaceID])
        )
        let exactPending = try initialStore.prepareRegistration(
            label: "Current target",
            statusScope: .exactTarget(paneID: agents[0].paneID, targetVersion: agents[0].targetVersion)
        )
        let slowPending = try initialStore.prepareRegistration(
            label: "Slow reader",
            statusScope: .persistentWorkspaces([agents[0].workspaceID])
        )
        let registrations = [firstPending, secondPending, exactPending, slowPending]
        for pending in registrations {
            try await storeCredential(
                helper: helper,
                profile: profile,
                connectionID: pending.connection.id,
                credential: pending.credential
            )
            try initialStore.activateRegistration(pending)
        }
        defer {
            for pending in registrations {
                try? deleteCredential(helper: helper, profile: profile, connectionID: pending.connection.id)
            }
        }

        var server: LocalAPIServer? = try makeGrantServer(
            profile: profile,
            accessStore: initialStore,
            roster: roster,
            captureGate: captureGate
        )
        guard let initialServer = server else { throw E2EFailure(message: "grant server unavailable") }
        initialStore.setInvalidationHandler { [weak initialServer] connectionID in
            initialServer?.invalidate(connectionID: connectionID)
        }
        initialServer.start()

        let disabled = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        try check(disabled.error == .accessDisabled && disabled.agents == nil, "registration grants nothing while global access is off")

        let missing = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: UUID()
        )
        try check(missing.error == .credentialUnavailable && missing.agents == nil, "unregistered handle fails before requesting content")

        try initialStore.setGloballyEnabled(true)
        let labelOnly = try await Task.detached {
            try LocalAPIClient.call(
                LocalAPIRequest(
                    profile: profile,
                    operation: .listAgents,
                    connectionID: firstPending.connection.id
                )
            )
        }.value
        try check(labelOnly.error == .permissionDenied && labelOnly.agents == nil, "connection identity without its credential is denied")

        let wrongCredential = try LocalAPICredentialKeychain.generate()
        let wrong = try await Task.detached {
            try LocalAPIClient.call(
                LocalAPIRequest(
                    profile: profile,
                    operation: .listAgents,
                    connectionID: firstPending.connection.id,
                    credential: LocalAPICredential.encode(wrongCredential)
                )
            )
        }.value
        try check(wrong.error == .permissionDenied && wrong.agents == nil, "wrong credential fails closed without metadata")

        let crossProfile = "development:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let crossProfileResponse = try await callHelper(
            helper: helper,
            profile: crossProfile,
            connectionID: firstPending.connection.id
        )
        try check(
            crossProfileResponse.error == .credentialUnavailable && crossProfileResponse.agents == nil,
            "credential handles are isolated by profile"
        )

        let first = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        let second = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        try check(
            first.error == nil && first.agents?.map(\.paneID) == [agents[0].paneID],
            "Client A receives only its selected pane"
        )
        try check(
            second.error == nil && Set(second.agents?.map(\.paneID) ?? []) == Set(agents.map(\.paneID)),
            "Client B receives its independently selected workspace"
        )

        let capabilities = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id,
            operation: .capabilities
        )
        try check(
            capabilities.capabilities?.context == false
                && capabilities.capabilities?.instructions == false
                && capabilities.capabilities?.monitoring == false,
            "context instructions and monitoring remain unavailable"
        )

        let exactInitial = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: exactPending.connection.id
        )
        try check(exactInitial.agents?.map(\.paneID) == [agents[0].paneID], "exact grant starts at the reviewed target incarnation")
        roster.replaceTargetVersion(for: agents[0].paneID)
        let exactExpired = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: exactPending.connection.id
        )
        try check(
            exactExpired.error == nil && exactExpired.agents?.isEmpty == true, "exact grant expires when the target incarnation changes")

        captureGate.arm()
        let editing = Task.detached {
            try await callHelper(
                helper: helper,
                profile: profile,
                connectionID: firstPending.connection.id
            )
        }
        await captureGate.waitUntilEntered()
        try initialStore.updateStatusScope(
            connectionID: firstPending.connection.id,
            statusScope: .persistentPanes([agents[1].paneID])
        )
        let editedInFlight = try await editing.value
        try check(
            editedInFlight.error != nil && editedInFlight.agents == nil,
            "scope edit during capture prevents the old response"
        )
        let edited = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        try check(edited.agents?.map(\.paneID) == [agents[1].paneID], "scope edit applies to the next read")

        let accessDirectory = supportDirectory.appending(path: "LocalAPI", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: accessDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accessDirectory.path) }
        var scopeSaveFailed = false
        do {
            try initialStore.updateStatusScope(
                connectionID: firstPending.connection.id,
                statusScope: .persistentPanes([agents[0].paneID])
            )
        } catch LocalAPIAccessFailure.persistenceFailed {
            scopeSaveFailed = true
        }
        try check(
            scopeSaveFailed && initialStore.persistenceFailureMessage != nil,
            "failed scope save keeps a visible retry state"
        )
        let deniedAfterFailedSave = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        try check(
            deniedAfterFailedSave.error == .permissionDenied && deniedAfterFailedSave.agents == nil,
            "failed scope save denies the connection immediately"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accessDirectory.path)
        try initialStore.retryPersistence()
        let retried = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: firstPending.connection.id
        )
        let persistedData = try Data(contentsOf: accessDirectory.appending(path: "access.json"))
        let persistedDecoder = JSONDecoder()
        persistedDecoder.dateDecodingStrategy = .iso8601
        let persistedState = try persistedDecoder.decode(LocalAPIAccessState.self, from: persistedData)
        try check(
            initialStore.persistenceFailureMessage == nil
                && retried.agents?.map(\.paneID) == [agents[0].paneID]
                && persistedState.connections.first(where: { $0.id == firstPending.connection.id })?.statusScope
                    == .persistentPanes([agents[0].paneID]),
            "retry persists and restores the requested scope"
        )

        let retainedFirstCredential = LocalAPICredential.encode(firstPending.credential)
        try initialStore.revoke(connectionID: firstPending.connection.id)
        let revoked = try await Task.detached {
            try LocalAPIClient.call(
                LocalAPIRequest(
                    profile: profile,
                    operation: .listAgents,
                    connectionID: firstPending.connection.id,
                    credential: retainedFirstCredential
                )
            )
        }.value
        try check(revoked.error == .permissionDenied && revoked.agents == nil, "revoked credential is denied even before Keychain deletion")
        try deleteCredential(helper: helper, profile: profile, connectionID: firstPending.connection.id)
        let secondAfterRevoke = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        try check(secondAfterRevoke.error == nil && secondAfterRevoke.agents != nil, "revoking Client A leaves Client B working")

        roster.repeatCurrentAgents(count: 350)
        let slowClient = try E2ESlowClient(
            profile: profile,
            connectionID: slowPending.connection.id,
            credential: slowPending.credential
        )
        try await Task.sleep(for: .milliseconds(150))
        let revokeStart = ContinuousClock.now
        try initialStore.revoke(connectionID: slowPending.connection.id)
        let revokeDuration = revokeStart.duration(to: .now)
        try check(revokeDuration < .milliseconds(250), "slow reader cannot stall connection revocation")
        try check(!slowClient.receivedCompleteFrame(), "slow reader cannot complete a response after revocation")
        try deleteCredential(helper: helper, profile: profile, connectionID: slowPending.connection.id)
        roster.setAgents(agents)

        captureGate.arm()
        let disabling = Task.detached {
            try await callHelper(
                helper: helper,
                profile: profile,
                connectionID: secondPending.connection.id
            )
        }
        await captureGate.waitUntilEntered()
        try initialStore.setGloballyEnabled(false)
        let disabledInFlight = try await disabling.value
        try check(
            disabledInFlight.error != nil && disabledInFlight.agents == nil,
            "global disable prevents an in-flight response"
        )
        let disabledNewRead = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        try check(disabledNewRead.error == .accessDisabled && disabledNewRead.agents == nil, "global disable blocks new reads")
        try initialStore.setGloballyEnabled(true)

        initialServer.stop()
        try await Task.sleep(for: .milliseconds(150))
        initialStore.relinquishAuthority()
        server = nil
        accessStore = nil
        let restartedStore = LocalAPIAccessStore(profile: profile, supportDirectoryURL: supportDirectory)
        try check(
            restartedStore.ownsAuthority && restartedStore.loadFailure == nil
                && restartedStore.state.globallyEnabled && restartedStore.state.connections.count == 2,
            "global state and remaining grants persist across restart"
        )
        let restartedServer = try makeGrantServer(
            profile: profile,
            accessStore: restartedStore,
            roster: roster,
            captureGate: captureGate
        )
        restartedStore.setInvalidationHandler { [weak restartedServer] connectionID in
            restartedServer?.invalidate(connectionID: connectionID)
        }
        restartedServer.start()
        defer {
            restartedServer.stop()
            restartedStore.relinquishAuthority()
        }
        let afterRestart = try await callHelper(
            helper: helper,
            profile: profile,
            connectionID: secondPending.connection.id
        )
        try check(afterRestart.error == nil && afterRestart.agents != nil, "remaining helper credential works after app restart")

        let credentialNeedles = registrations.flatMap { pending -> [Data] in
            let encoded = LocalAPICredential.encode(pending.credential) ?? ""
            return [pending.credential, Data(encoded.utf8)]
        }
        let artifactFiles = (FileManager.default.enumerator(at: artifact, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let artifactData = try artifactFiles.filter(\.isFileURL).reduce(into: Data()) { aggregate, url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
            aggregate.append(try Data(contentsOf: url))
        }
        try check(
            credentialNeedles.allSatisfy { !artifactData.contains($0) },
            "E2E artifacts contain no raw or encoded credentials"
        )

        let grantReport: [String: Any] = [
            "kind": "profile-scoped grant authorization through helper Keychain handles",
            "profile": profile,
            "checks": checks,
            "credentials": "omitted",
        ]
        try JSONSerialization.data(withJSONObject: grantReport, options: [.prettyPrinted, .sortedKeys]).write(
            to: artifact.appending(path: "grant-report.json")
        )
        return checks
    }

    @MainActor
    private static func makeGrantServer(
        profile: String,
        accessStore: LocalAPIAccessStore,
        roster: E2EAgentRoster,
        captureGate: E2ECaptureGate
    ) throws -> LocalAPIServer {
        try LocalAPIServer(profile: profile, authorization: accessStore.runtimeAuthority.provider) { request, instance, lease in
            await captureGate.enterIfArmed()
            let scopedAgents = roster.current.filter {
                lease.statusScope.allows(
                    paneID: $0.paneID,
                    workspaceID: $0.workspaceID,
                    targetVersion: $0.targetVersion
                )
            }
            return LocalAPIResponse(
                requestID: request.requestID,
                profile: profile,
                appInstanceID: instance,
                capturedAt: Date(),
                connectionStatus: request.operation == LocalAPIOperation.connectionStatus.rawValue ? .connected : nil,
                capabilities: request.operation == LocalAPIOperation.capabilities.rawValue ? LocalAPICapabilities() : nil,
                agents: request.operation == LocalAPIOperation.listAgents.rawValue ? scopedAgents : nil
            )
        }
    }

    static func callHelper(
        helper: String,
        profile: String,
        connectionID: UUID,
        operation: LocalAPIOperation = .listAgents
    ) async throws -> LocalAPIResponse {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [
                "--profile", profile,
                "--credential-handle", connectionID.uuidString.lowercased(),
                operation.rawValue,
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try process.waitUntilExitEventually()
            return try LocalAPIContract.decoder().decode(LocalAPIResponse.self, from: data)
        }.value
    }
}

private final class E2EAgentRoster: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [LocalAPIAgent]

    init(_ agents: [LocalAPIAgent]) { self.agents = agents }

    var current: [LocalAPIAgent] { lock.withLock { agents } }

    func replaceTargetVersion(for paneID: UUID) {
        lock.withLock {
            agents = agents.map { agent in
                guard agent.paneID == paneID else { return agent }
                return LocalAPIAgent(
                    paneID: agent.paneID,
                    workspaceID: agent.workspaceID,
                    workspaceName: agent.workspaceName,
                    provider: agent.provider,
                    executionLocation: agent.executionLocation,
                    availability: agent.availability,
                    state: agent.state,
                    attentionReason: agent.attentionReason,
                    unreadCount: agent.unreadCount,
                    stateProvenance: agent.stateProvenance,
                    observedAt: agent.observedAt,
                    capturedAt: Date(),
                    targetVersion: UUID(),
                    identityEvidence: agent.identityEvidence,
                    providerSessionID: agent.providerSessionID,
                    capabilities: agent.capabilities
                )
            }
        }
    }

    func repeatCurrentAgents(count: Int) {
        lock.withLock {
            let current = agents
            agents = (0..<count).map { current[$0 % current.count] }
        }
    }

    func setAgents(_ agents: [LocalAPIAgent]) {
        lock.withLock { self.agents = agents }
    }
}

private final class E2ESlowClient {
    private let fd: Int32

    init(profile: String, connectionID: UUID, credential: Data) throws {
        let endpoint = try LocalAPIEndpoint(profile: profile)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw E2EFailure(message: "could not create slow client socket") }
        var receiveBuffer: Int32 = 1024
        guard setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw E2EFailure(message: "could not constrain slow client receive buffer")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(endpoint.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.map { UInt8(bitPattern: $0) })
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw E2EFailure(message: "could not connect slow client")
        }
        let request = LocalAPIRequest(
            profile: profile,
            operation: .listAgents,
            connectionID: connectionID,
            credential: LocalAPICredential.encode(credential)
        )
        let body = try LocalAPIContract.encoder().encode(request)
        let length = UInt32(body.count)
        var frame = Data([
            UInt8((length >> 24) & 255),
            UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255),
            UInt8(length & 255),
        ])
        frame.append(body)
        let sent = frame.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!, frame.count)
        }
        guard sent == frame.count else {
            close(fd)
            throw E2EFailure(message: "could not send slow client request")
        }
    }

    deinit { close(fd) }

    func receivedCompleteFrame() -> Bool {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                continue
            }
            break
        }
        guard received.count >= 4 else { return false }
        let length = received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return received.count >= Int(length) + 4
    }
}

private final class E2ECaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var entered: CheckedContinuation<Void, Never>?

    func arm() { lock.withLock { armed = true } }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if !armed { return true }
                entered = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func enterIfArmed() async {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard armed else { return nil }
            armed = false
            let continuation = entered
            entered = nil
            return continuation
        }
        continuation?.resume()
        try? await Task.sleep(for: .milliseconds(250))
    }
}

private final class E2EAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private let lease = LocalAPIAuthorizationLease(
        connectionID: UUID(),
        globalRevision: UUID(),
        connectionRevision: UUID(),
        statusScope: .persistentPanes([UUID()])
    )
    var provider: LocalAPIAuthorizationProvider {
        LocalAPIAuthorizationProvider(
            authorize: { [weak self] _, expected in
                guard let self else { return .failure(.permissionDenied) }
                return self.lock.withLock {
                    guard self.enabled, expected == nil || expected == self.lease else {
                        return .failure(.permissionDenied)
                    }
                    return .success(self.lease)
                }
            },
            commit: { [weak self] _, expected, body in
                guard let self else { throw LocalAPIError.permissionDenied }
                return try self.lock.withLock {
                    guard self.enabled, expected == self.lease else { throw LocalAPIError.permissionDenied }
                    return try body()
                }
            }
        )
    }
    func revoke() { lock.withLock { enabled = false } }
}
