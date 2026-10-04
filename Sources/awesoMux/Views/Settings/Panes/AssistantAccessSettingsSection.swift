import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Combine
import DesignSystem
import SwiftUI

struct AssistantAccessSettingsSection: View {
    @Environment(LocalAPIAccessStore.self) private var accessStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(GhosttyRuntime.self) private var ghosttyRuntime
    @State private var contextConsent: AssistantContextConsentRequest?
    @State private var contextErrorMessage: String?
    @State private var editor: ConnectionEditorRequest?
    @State private var editorErrorMessage: String?
    @State private var revoking: LocalAPIConnectionGrant?
    @State private var errorMessage: String?
    @State private var copyErrorMessage: String?
    @State private var isWorking = false
    @State private var contextTargetVersions: [UUID: UUID]?

    var body: some View {
        SettingsSection(
            index: 3,
            title: String(localized: "Outside app access", comment: "Agents settings title."),
            subtitle: String(
                localized:
                    "Let AI apps on this Mac, like Claude Desktop or ChatGPT, see what your agents are doing. You choose which panes each app can see.",
                comment: "Outside app access settings subtitle."
            )
        ) {
            SettingsField(
                label: String(localized: "Apps", comment: "Outside app access app list label."),
                hint: String(
                    localized: "Each app gets its own key. Removing one doesn't affect the others.",
                    comment: "Outside app access app list hint."
                ),
                isFirst: true
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if accessStore.state.connections.isEmpty {
                        Text(String(localized: "No apps added yet.", comment: "Empty outside app list."))
                            .foregroundStyle(Color.aw.text2)
                    } else {
                        ForEach(accessStore.state.connections) { connection in
                            connectionCard(connection)
                        }
                    }

                    Button(String(localized: "Add App…", comment: "Add outside app button.")) {
                        presentEditor()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMutate)
                }
            }

            SettingsField(
                label: String(localized: "Allow outside apps", comment: "Outside app access toggle label."),
                hint: accessStore.state.globallyEnabled
                    ? String(localized: "On — apps can see what's listed above.", comment: "Outside app access toggle state.")
                    : String(localized: "Off — no app can see anything.", comment: "Outside app access toggle state."),
                forwardsAccessibilityToControl: true
            ) {
                Toggle(
                    String(localized: "Allow outside apps", comment: "Outside app access toggle accessibility label."),
                    isOn: Binding(
                        get: { accessStore.state.globallyEnabled },
                        set: setGloballyEnabled
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!accessStore.ownsAuthority || accessStore.loadFailure != nil || isWorking)
            }

            SettingsField(
                label: String(localized: "Only add apps you trust", comment: "Outside app access safety label.")
            ) {
                Text(
                    String(
                        localized:
                            "Anything running under your Mac account can use an app's key once it knows it. Remove apps you stop using.",
                        comment: "Outside app access same-user boundary disclosure."
                    )
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let visibleErrorMessage {
                SettingsField(
                    label: visibleErrorLabel,
                    hint: visibleErrorMessage,
                    hintColor: Color.aw.peach
                ) {
                    HStack(spacing: 8) {
                        if accessStore.persistenceFailureMessage != nil {
                            Button(String(localized: "Retry Save", comment: "Retry assistant access metadata save.")) {
                                retryPersistence()
                            }
                        } else {
                            Button(String(localized: "Dismiss", comment: "Dismiss assistant access error.")) {
                                errorMessage = nil
                                copyErrorMessage = nil
                            }
                        }
                    }
                }
            }
        }
        .task(id: accessStore.state.connections.filter { $0.contextGrant != nil }.map(\.id)) {
            guard accessStore.state.connections.contains(where: { $0.contextGrant != nil }) else {
                contextTargetVersions = [:]
                return
            }
            contextTargetVersions = try? await captureTargetVersions()
            for await _ in Timer.publish(every: 2, on: .main, in: .common).autoconnect().values {
                guard !Task.isCancelled else { return }
                contextTargetVersions = try? await captureTargetVersions()
            }
        }
        .sheet(item: $editor) { request in
            AssistantConnectionEditor(
                request: request,
                workspaces: workspaces,
                panes: panes,
                isWorking: isWorking,
                errorMessage: editorErrorMessage,
                save: save
            )
        }
        .sheet(item: $contextConsent) { request in
            AssistantContextConsent(
                request: request, isWorking: isWorking, errorMessage: contextErrorMessage,
                save: { allowHistory in saveContext(request, allowHistory: allowHistory) }
            )
        }
        .confirmationDialog(
            String(localized: "Remove app?", comment: "Remove outside app confirmation title."),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible,
            presenting: revoking
        ) { connection in
            Button(
                String(format: String(localized: "Remove %@", comment: "Remove named outside app."), connection.label),
                role: .destructive
            ) {
                revoke(connection)
            }
        } message: { connection in
            Text(
                String(
                    format: String(
                        localized: "%@ will lose access right away. Other apps keep their access.",
                        comment: "Remove outside app confirmation message."
                    ), connection.label
                )
            )
        }
    }

    private var canMutate: Bool {
        accessStore.ownsAuthority && accessStore.loadFailure == nil && !isWorking
    }

    private var visibleErrorMessage: String? {
        accessStore.persistenceFailureMessage ?? errorMessage ?? copyErrorMessage
    }

    private var visibleErrorLabel: String {
        if accessStore.persistenceFailureMessage == nil, errorMessage == nil, copyErrorMessage != nil {
            return String(localized: "Copy failed", comment: "Outside app setup-command copy error label.")
        }
        return String(localized: "Access change failed", comment: "Assistant access error label.")
    }

    private var workspaces: [AssistantAccessWorkspace] {
        sessionStore.groups.flatMap(\.sessions).map {
            AssistantAccessWorkspace(id: $0.id, title: $0.title)
        }
    }

    private var panes: [AssistantAccessPane] {
        sessionStore.groups.flatMap(\.sessions).flatMap { workspace in
            workspace.panes.map {
                AssistantAccessPane(id: $0.id, title: $0.title, workspaceTitle: workspace.title)
            }
        }
    }

    private func presentEditor(_ connection: LocalAPIConnectionGrant? = nil) {
        isWorking = true
        editorErrorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let targetVersions = try await captureTargetVersions()
                let currentTarget = LocalAPITargetScope.currentTarget(
                    activePaneID: sessionStore.selectedSession?.activePaneID,
                    targetVersions: targetVersions
                )
                let selectedPaneID: UUID? =
                    switch currentTarget {
                    case .exactTarget(let paneID, _): paneID
                    default: nil
                    }
                let selectedWorkspace = sessionStore.selectedSessionID ?? workspaces.first?.id

                let request: ConnectionEditorRequest
                switch connection?.statusScope {
                case .exactTarget(let paneID, let targetVersion):
                    request = ConnectionEditorRequest(
                        connectionID: connection?.id,
                        label: connection?.label ?? "",
                        scopeKind: .currentTarget,
                        selectedPaneIDs: [paneID],
                        selectedWorkspaceIDs: [],
                        targetVersions: targetVersions,
                        reviewedExactTarget: AssistantAccessReviewedTarget(
                            paneID: paneID,
                            targetVersion: targetVersion
                        )
                    )
                case .persistentPanes(let paneIDs):
                    request = ConnectionEditorRequest(
                        connectionID: connection?.id,
                        label: connection?.label ?? "",
                        scopeKind: .panes,
                        selectedPaneIDs: Set(paneIDs),
                        selectedWorkspaceIDs: [],
                        targetVersions: targetVersions
                    )
                case .persistentWorkspaces(let workspaceIDs):
                    request = ConnectionEditorRequest(
                        connectionID: connection?.id,
                        label: connection?.label ?? "",
                        scopeKind: .workspaces,
                        selectedPaneIDs: [],
                        selectedWorkspaceIDs: Set(workspaceIDs),
                        targetVersions: targetVersions
                    )
                case nil:
                    request = ConnectionEditorRequest(
                        connectionID: nil,
                        label: "",
                        scopeKind: .currentTarget,
                        selectedPaneIDs: selectedPaneID.map { [$0] } ?? [],
                        selectedWorkspaceIDs: selectedWorkspace.map { [$0] } ?? [],
                        targetVersions: targetVersions
                    )
                }
                editor = request
            } catch {
                errorMessage = String(localized: "awesoMux couldn't check which panes are available. Try again.")
            }
        }
    }

    private func captureTargetVersions() async throws -> [UUID: UUID] {
        let providers = try sessionStore.localAPIProviders()
        let keys = sessionStore.localAPIRoutingKeys()
        let sources = ghosttyRuntime.localAPIProcessSources()
        let incarnations = await Task.detached(priority: .utility) {
            sources.reduce(into: [UUID: String]()) { result, item in
                guard !Task.isCancelled, let provider = providers[item.key], provider != .shell,
                    let incarnation = item.value.agentIncarnation(provider: provider)
                else { return }
                result[item.key] = incarnation
            }
        }.value
        guard providers == (try sessionStore.localAPIProviders()),
            keys == sessionStore.localAPIRoutingKeys(),
            sources == ghosttyRuntime.localAPIProcessSources()
        else { throw LocalAPIError.staleTarget }
        return Dictionary(
            uniqueKeysWithValues: sessionStore.localAPIAgents(processIncarnations: incarnations).map {
                ($0.paneID, $0.targetVersion)
            })
    }

    @ViewBuilder
    private func connectionCard(_ connection: LocalAPIConnectionGrant) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(connection.label)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)

            accessRow(
                name: String(localized: "Can see agent status"),
                value: scopeSummary(connection.statusScope),
                detail: scopeExplanation(connection.statusScope),
                isGranted: true
            )
            accessRow(
                name: String(localized: "Can read session details"),
                value: contextSummary(connection),
                isGranted: contextIsCurrent(connection)
            )
            if let grant = connection.contextGrant {
                accessRow(
                    name: String(localized: "Recent terminal output"),
                    value: contextIsCurrent(connection)
                        ? (grant.allowTerminalHistory ? String(localized: "Yes") : String(localized: "No"))
                        : contextSummary(connection),
                    isGranted: contextIsCurrent(connection) && grant.allowTerminalHistory
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { connectionActions(connection) }
                VStack(alignment: .leading, spacing: 8) { connectionActions(connection) }
            }
            .buttonStyle(.bordered)

            Text(String(localized: "Give the setup command to the app so it can check on your agents."))
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: AwRadius.button).fill(Color.aw.surface.elevated))
        .overlay(RoundedRectangle(cornerRadius: AwRadius.button).stroke(Color.aw.border, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func connectionActions(_ connection: LocalAPIConnectionGrant) -> some View {
        Button(String(localized: "Copy Setup Command")) { copyHelperCommand(connection) }
        Button(String(localized: "Change Access…")) { presentEditor(connection) }
            .disabled(!canMutate)
        Button(String(localized: "Share Session Details…")) { presentContextConsent(connection) }
            .disabled(!canMutate)
        if connection.contextGrant != nil {
            Button(String(localized: "Stop Sharing Details")) {
                do {
                    try accessStore.updateContextGrant(connectionID: connection.id, contextGrant: nil)
                    errorMessage = nil
                } catch {
                    errorMessage = String(localized: "awesoMux couldn't save this app's access.")
                }
            }
            .disabled(!canMutate)
        }
        Button(String(localized: "Remove"), role: .destructive) { revoking = connection }
            .disabled(!canMutate)
    }

    private func contextIsCurrent(_ connection: LocalAPIConnectionGrant) -> Bool {
        guard let grant = connection.contextGrant else { return false }
        return contextTargetVersions?[grant.paneID] == grant.targetVersion
    }

    private func contextSummary(_ connection: LocalAPIConnectionGrant) -> String {
        guard let grant = connection.contextGrant else { return String(localized: "No") }
        guard contextTargetVersions != nil else { return String(localized: "Checking access…") }
        guard contextIsCurrent(connection) else { return String(localized: "Access ended") }
        return paneTitle(grant.paneID)
    }

    private func presentContextConsent(_ connection: LocalAPIConnectionGrant) {
        guard let paneID = sessionStore.selectedSession?.activePaneID else {
            errorMessage = String(localized: "Select a pane running an agent, then try again.")
            return
        }
        isWorking = true
        contextErrorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let agent = try await LocalAPIService.sampleContextTarget(
                    paneID: paneID, store: sessionStore, runtime: ghosttyRuntime
                )
                guard agent.executionLocation == "local", agent.identityEvidence == "local_process_incarnation" else {
                    throw LocalAPIError.contextUnavailable
                }
                guard agent.providerSessionID != nil, let provider = AgentKind(rawValue: agent.provider),
                    [.claudeCode, .codex, .pi, .openCode].contains(provider)
                else {
                    errorMessage = String(
                        localized: "This agent's conversation isn't available yet. Wait for a supported agent session, then try again.")
                    return
                }
                contextConsent = AssistantContextConsentRequest(
                    connectionID: connection.id, connectionLabel: connection.label,
                    paneTitle: paneTitle(agent.paneID), agent: agent
                )
            } catch {
                errorMessage = String(
                    localized:
                        "awesoMux couldn't read the agent in the selected pane. Session details work only for agents running on this Mac.")
            }
        }
    }

    private func saveContext(_ request: AssistantContextConsentRequest, allowHistory: Bool) {
        isWorking = true
        contextErrorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let agent = try await LocalAPIService.sampleContextTarget(
                    paneID: request.agent.paneID, store: sessionStore, runtime: ghosttyRuntime
                )
                guard contextConsent?.id == request.id else { return }
                guard agent.targetVersion == request.agent.targetVersion else { throw LocalAPIError.staleTarget }
                try accessStore.updateContextGrant(
                    connectionID: request.connectionID,
                    contextGrant: LocalAPIContextGrant(
                        paneID: agent.paneID, targetVersion: agent.targetVersion, allowTerminalHistory: allowHistory
                    )
                )
                var versions = contextTargetVersions ?? [:]
                versions[agent.paneID] = agent.targetVersion
                contextTargetVersions = versions
                contextConsent = nil
                errorMessage = nil
            } catch {
                contextErrorMessage =
                    accessStore.persistenceFailureMessage
                    ?? String(localized: "The pane changed before saving. Review it and try again.")
            }
        }
    }

    private func accessRow(name: String, value: String, detail: String? = nil, isGranted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "minus.circle").accessibilityHidden(true)
            Text(name)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).foregroundStyle(Color.aw.text2)
                if let detail {
                    Text(detail).foregroundStyle(Color.aw.text3)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .awFont(AwFont.UI.meta)
        .accessibilityElement(children: .combine)
    }

    private func paneTitle(_ paneID: UUID) -> String {
        panes.first { $0.id == paneID }.map { "\($0.title) — \($0.workspaceTitle)" }
            ?? String(localized: "Closed pane")
    }

    private func scopeSummary(_ scope: LocalAPITargetScope) -> String {
        switch scope {
        case .exactTarget(let paneID, _):
            paneTitle(paneID)
        case .persistentPanes(let paneIDs):
            String.localizedStringWithFormat(String(localized: "%lld panes"), Int64(paneIDs.count))
        case .persistentWorkspaces(let workspaceIDs):
            String.localizedStringWithFormat(String(localized: "%lld workspaces"), Int64(workspaceIDs.count))
        }
    }

    private func scopeExplanation(_ scope: LocalAPITargetScope) -> String {
        switch scope {
        case .exactTarget: AssistantAccessScopeKind.currentTarget.explanation
        case .persistentPanes: AssistantAccessScopeKind.panes.explanation
        case .persistentWorkspaces: AssistantAccessScopeKind.workspaces.explanation
        }
    }

    private func helperCommand(_ connection: LocalAPIConnectionGrant) -> String {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/MacOS/awesomux-agent").path
        return
            "\(helper.shellQuoted) --profile \(accessStore.state.profile.shellQuoted) --credential-handle \(connection.id.uuidString.lowercased()) list_agents"
    }

    private func copyHelperCommand(_ connection: LocalAPIConnectionGrant) {
        copyErrorMessage = nil
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(helperCommand(connection), forType: .string) else {
            let message = String(localized: "awesoMux couldn't copy the setup command.")
            copyErrorMessage = message
            TerminalAccessibilityAnnouncer.announce(message)
            return
        }
    }

    private func setGloballyEnabled(_ enabled: Bool) {
        do {
            try accessStore.setGloballyEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage =
                accessStore.persistenceFailureMessage
                ?? String(localized: "awesoMux couldn't save the access setting.")
        }
    }

    private func save(_ request: ConnectionEditorRequest, scope: LocalAPITargetScope) {
        isWorking = true
        editorErrorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if let connectionID = request.connectionID {
                    try accessStore.updateStatusScope(connectionID: connectionID, statusScope: scope)
                } else {
                    _ = try await LocalAPICredentialBroker().register(
                        in: accessStore,
                        label: request.label,
                        statusScope: scope
                    )
                }
                editor = nil
                errorMessage = nil
            } catch LocalAPICredentialBrokerError.cleanupFailed {
                editorErrorMessage = String(
                    localized:
                        "The app wasn't added, and awesoMux couldn't remove its unused Keychain key."
                )
            } catch {
                editorErrorMessage =
                    accessStore.persistenceFailureMessage
                    ?? String(localized: "awesoMux couldn't save this app's access.")
            }
        }
    }

    private func retryPersistence() {
        do {
            try accessStore.retryPersistence()
            errorMessage = nil
        } catch {
            errorMessage =
                accessStore.persistenceFailureMessage
                ?? String(localized: "awesoMux couldn't save the access setting.")
        }
    }

    private func revoke(_ connection: LocalAPIConnectionGrant) {
        revoking = nil
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await LocalAPICredentialBroker().revoke(connectionID: connection.id, in: accessStore)
            } catch {
                errorMessage =
                    accessStore.persistenceFailureMessage
                    ?? String(localized: "This app no longer has access, but awesoMux couldn't finish removing it.")
            }
        }
    }
}

private struct AssistantAccessWorkspace: Identifiable {
    let id: UUID
    let title: String
}

private struct AssistantAccessPane: Identifiable {
    let id: UUID
    let title: String
    let workspaceTitle: String
}

private enum AssistantAccessScopeKind: String, CaseIterable, Identifiable {
    case currentTarget
    case panes
    case workspaces

    var id: Self { self }

    var title: String {
        switch self {
        case .currentTarget: String(localized: "This pane")
        case .panes: String(localized: "Selected panes")
        case .workspaces: String(localized: "Selected workspaces")
        }
    }

    var explanation: String {
        switch self {
        case .currentTarget: String(localized: "Access ends if this pane restarts.")
        case .panes: String(localized: "Keeps access to these panes.")
        case .workspaces: String(localized: "Includes new panes added to these workspaces.")
        }
    }
}

private struct ConnectionEditorRequest: Identifiable {
    let id = UUID()
    let connectionID: UUID?
    var label: String
    var scopeKind: AssistantAccessScopeKind
    var selectedPaneIDs: Set<UUID>
    var selectedWorkspaceIDs: Set<UUID>
    var targetVersions: [UUID: UUID]
    var reviewedExactTarget: AssistantAccessReviewedTarget? = nil
}

private struct AssistantAccessReviewedTarget {
    let paneID: UUID
    let targetVersion: UUID
}

private struct AssistantConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionEditorRequest
    let workspaces: [AssistantAccessWorkspace]
    let panes: [AssistantAccessPane]
    let isWorking: Bool
    let errorMessage: String?
    let save: (ConnectionEditorRequest, LocalAPITargetScope) -> Void

    init(
        request: ConnectionEditorRequest,
        workspaces: [AssistantAccessWorkspace],
        panes: [AssistantAccessPane],
        isWorking: Bool,
        errorMessage: String?,
        save: @escaping (ConnectionEditorRequest, LocalAPITargetScope) -> Void
    ) {
        _draft = State(initialValue: request)
        self.workspaces = workspaces
        self.panes = panes
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.connectionID == nil ? String(localized: "Add App") : String(localized: "Change Access"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if draft.connectionID == nil {
                TextField(String(localized: "App name"), text: $draft.label)
                    .accessibilityLabel(String(localized: "App name"))
                Text(
                    String(
                        localized:
                            "awesoMux saves a key for this app in your Keychain. You never need to see or copy it.",
                        comment: "Outside app key disclosure."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(draft.label).font(.headline)
            }

            Picker(String(localized: "Can see agent status in"), selection: $draft.scopeKind) {
                ForEach(AssistantAccessScopeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch draft.scopeKind {
                    case .currentTarget:
                        Picker(String(localized: "Pane"), selection: selectedExactPaneID) {
                            ForEach(panes.filter { draft.targetVersions[$0.id] != nil }) { pane in
                                Text("\(pane.title) — \(pane.workspaceTitle)").tag(Optional(pane.id))
                            }
                        }
                    case .panes:
                        ForEach(panes) { pane in
                            Toggle(
                                isOn: setBinding(pane.id, in: $draft.selectedPaneIDs)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pane.title)
                                    Text(pane.workspaceTitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    case .workspaces:
                        ForEach(workspaces) { workspace in
                            Toggle(workspace.title, isOn: setBinding(workspace.id, in: $draft.selectedWorkspaceIDs))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 280)

            Text(draft.scopeKind.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let exactTargetExpiryMessage {
                Label(
                    exactTargetExpiryMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.aw.peach)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.aw.peach)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(format: String(localized: "Access change failed: %@"), errorMessage))
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.connectionID == nil ? String(localized: "Add App") : String(localized: "Save")) {
                    save(draft, selectedScope)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var selectedScope: LocalAPITargetScope {
        switch draft.scopeKind {
        case .currentTarget:
            let paneID = draft.selectedPaneIDs.first!
            let currentTargetVersion = draft.targetVersions[paneID]!
            return .exactTarget(paneID: paneID, targetVersion: currentTargetVersion)
        case .panes:
            return .persistentPanes(draft.selectedPaneIDs.sorted { $0.uuidString < $1.uuidString })
        case .workspaces:
            return .persistentWorkspaces(draft.selectedWorkspaceIDs.sorted { $0.uuidString < $1.uuidString })
        }
    }

    private var canSave: Bool {
        let hasSelection: Bool
        switch draft.scopeKind {
        case .currentTarget:
            hasSelection =
                draft.selectedPaneIDs.count == 1
                && draft.selectedPaneIDs.first.flatMap { draft.targetVersions[$0] } != nil
        case .panes:
            hasSelection = !draft.selectedPaneIDs.isEmpty
        case .workspaces:
            hasSelection = !draft.selectedWorkspaceIDs.isEmpty
        }
        return hasSelection && (draft.connectionID != nil || !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var exactTargetExpiryMessage: String? {
        guard draft.scopeKind == .currentTarget,
            let reviewed = draft.reviewedExactTarget,
            draft.selectedPaneIDs == [reviewed.paneID]
        else { return nil }
        guard let currentTargetVersion = draft.targetVersions[reviewed.paneID] else {
            return String(localized: "Access ended because this pane restarted. Choose a pane to give access again.")
        }
        guard currentTargetVersion != reviewed.targetVersion else { return nil }
        return String(
            localized:
                "This pane restarted since access was last saved. Saving gives access to the pane as it is now."
        )
    }

    private var selectedExactPaneID: Binding<UUID?> {
        Binding(
            get: { draft.selectedPaneIDs.first },
            set: { draft.selectedPaneIDs = $0.map { [$0] } ?? [] }
        )
    }

    private func setBinding(_ id: UUID, in selection: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { selected in
                if selected {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        )
    }
}

private extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
