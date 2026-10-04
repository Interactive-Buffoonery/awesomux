import AppKit
import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
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

    var body: some View {
        SettingsSection(
            index: 3,
            title: String(localized: "Assistant access", comment: "Agents settings title."),
            subtitle: String(
                localized: "Register local client connections and choose which status and session context they may read.",
                comment: "Assistant access settings subtitle."
            )
        ) {
            SettingsField(
                label: String(localized: "Allow assistant access", comment: "Assistant access setting label."),
                hint: String(
                    localized: "Off blocks every connection immediately. Installing a client or registering it does not turn access on.",
                    comment: "Assistant access global toggle hint."
                ),
                isFirst: true,
                forwardsAccessibilityToControl: true
            ) {
                Toggle(
                    String(localized: "Allow assistant access", comment: "Assistant access toggle accessibility label."),
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
                label: String(localized: "Connected-computer access", comment: "Assistant access boundary label."),
                hint: String(
                    localized: "Credentials identify separate connections, not ChatGPT or other service accounts.",
                    comment: "Assistant access identity boundary hint."
                )
            ) {
                Text(
                    String(
                        localized:
                            "Any process running as your macOS user can invoke the bundled helper with a known handle. Review grants as access to this Mac and revoke connections you no longer use.",
                        comment: "Assistant access same-user boundary disclosure."
                    )
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsField(
                label: String(localized: "Connections", comment: "Assistant access connections label."),
                hint: String(
                    localized: "Each connection has its own Keychain credential and independently revocable status scope.",
                    comment: "Assistant access connections hint."
                )
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if accessStore.state.connections.isEmpty {
                        Text(String(localized: "No connections registered.", comment: "Empty assistant connections state."))
                            .foregroundStyle(Color.aw.text2)
                    } else {
                        ForEach(accessStore.state.connections) { connection in
                            connectionCard(connection)
                        }
                    }

                    Button(String(localized: "Register Connection…", comment: "Register assistant connection button.")) {
                        presentEditor()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMutate)
                }
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
            String(localized: "Revoke connection?", comment: "Revoke assistant connection confirmation title."),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible,
            presenting: revoking
        ) { connection in
            Button(
                String(format: String(localized: "Revoke %@", comment: "Revoke named assistant connection."), connection.label),
                role: .destructive
            ) {
                revoke(connection)
            }
        } message: { connection in
            Text(
                String(
                    format: String(
                        localized: "%@ will lose access immediately. Other connections keep their own grants.",
                        comment: "Revoke assistant connection confirmation message."
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
            return String(localized: "Copy failed", comment: "Assistant helper-command copy error label.")
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
                errorMessage = String(localized: "awesoMux could not verify current targets for this connection.")
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
            HStack(alignment: .firstTextBaseline) {
                Text(connection.label)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                Spacer()
                Text(scopeSummary(connection.statusScope))
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
            }

            capabilityRow(name: String(localized: "Status"), value: String(localized: "Granted"), systemImage: "checkmark.circle.fill")
            capabilityRow(
                name: String(localized: "Context"),
                value: connection.contextGrant == nil ? String(localized: "Off") : String(localized: "Exact target grant"),
                systemImage: connection.contextGrant == nil ? "minus.circle" : "checkmark.circle.fill"
            )
            if let grant = connection.contextGrant {
                Text(grant.paneID.uuidString.lowercased())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "Context target pane"))
                capabilityRow(
                    name: String(localized: "Terminal history"),
                    value: grant.allowTerminalHistory ? String(localized: "Granted") : String(localized: "Off"),
                    systemImage: grant.allowTerminalHistory ? "checkmark.circle.fill" : "minus.circle"
                )
            }
            HStack {
                Button(String(localized: "Share Current Target Context…")) { presentContextConsent(connection) }
                    .disabled(!canMutate)
                if connection.contextGrant != nil {
                    Button(String(localized: "Stop Context Sharing")) {
                        do {
                            try accessStore.updateContextGrant(connectionID: connection.id, contextGrant: nil)
                            errorMessage = nil
                        } catch {
                            errorMessage = String(localized: "awesoMux could not save this connection.")
                        }
                    }
                    .disabled(!canMutate)
                }
            }
            .buttonStyle(.bordered)
            capabilityRow(
                name: String(localized: "Reviewed instructions"), value: String(localized: "Unavailable"), systemImage: "minus.circle")
            capabilityRow(name: String(localized: "Direct delivery"), value: String(localized: "Unavailable"), systemImage: "minus.circle")
            capabilityRow(name: String(localized: "Monitoring"), value: String(localized: "Unavailable"), systemImage: "minus.circle")

            Text(helperCommand(connection))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.aw.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(String(localized: "Helper command"))

            HStack(spacing: 8) {
                Button(String(localized: "Copy Helper Command")) {
                    copyHelperCommand(connection)
                }
                Button(String(localized: "Edit Scope…")) { presentEditor(connection) }
                    .disabled(!canMutate)
                Button(String(localized: "Revoke"), role: .destructive) { revoking = connection }
                    .disabled(!canMutate)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: AwRadius.button).fill(Color.aw.surface.elevated))
        .overlay(RoundedRectangle(cornerRadius: AwRadius.button).stroke(Color.aw.border, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private func presentContextConsent(_ connection: LocalAPIConnectionGrant) {
        guard let paneID = sessionStore.selectedSession?.activePaneID else {
            errorMessage = String(localized: "Select an available agent pane before sharing context.")
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
                contextConsent = AssistantContextConsentRequest(
                    connectionID: connection.id, connectionLabel: connection.label, agent: agent
                )
            } catch {
                errorMessage = String(localized: "awesoMux could not verify the selected agent target for context sharing.")
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
                contextConsent = nil
                errorMessage = nil
            } catch {
                contextErrorMessage =
                    accessStore.persistenceFailureMessage
                    ?? String(localized: "The target changed or context sharing could not be saved. Review the current target again.")
            }
        }
    }

    private func capabilityRow(name: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(name)
            Spacer()
            Text(value).foregroundStyle(Color.aw.text2)
        }
        .awFont(AwFont.UI.meta)
        .accessibilityElement(children: .combine)
    }

    private func scopeSummary(_ scope: LocalAPITargetScope) -> String {
        switch scope {
        case .exactTarget:
            String(localized: "Current target")
        case .persistentPanes(let paneIDs):
            String.localizedStringWithFormat(String(localized: "%lld panes"), Int64(paneIDs.count))
        case .persistentWorkspaces(let workspaceIDs):
            String.localizedStringWithFormat(String(localized: "%lld workspaces"), Int64(workspaceIDs.count))
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
            let message = String(localized: "awesoMux could not copy the helper command.")
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
                ?? String(localized: "awesoMux could not save the access setting.")
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
                        "The connection was not registered, and awesoMux could not remove its unused Keychain credential."
                )
            } catch {
                editorErrorMessage =
                    accessStore.persistenceFailureMessage
                    ?? String(localized: "awesoMux could not save this connection.")
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
                ?? String(localized: "awesoMux could not save the access setting.")
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
                    ?? String(localized: "Access is denied, but awesoMux could not finish removing this connection.")
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
        case .currentTarget: String(localized: "Current target")
        case .panes: String(localized: "Selected panes")
        case .workspaces: String(localized: "Selected workspaces")
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
            Text(draft.connectionID == nil ? String(localized: "Register Connection") : String(localized: "Edit Status Scope"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if draft.connectionID == nil {
                TextField(String(localized: "Connection name"), text: $draft.label)
                    .accessibilityLabel(String(localized: "Connection name"))
                Text(
                    String(
                        localized:
                            "Registration creates a credential in your Keychain through the bundled helper. The credential is never shown or copied.",
                        comment: "Assistant registration credential disclosure."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(draft.label).font(.headline)
            }

            Picker(String(localized: "Status access"), selection: $draft.scopeKind) {
                ForEach(AssistantAccessScopeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch draft.scopeKind {
                    case .currentTarget:
                        Picker(String(localized: "Target pane"), selection: selectedExactPaneID) {
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

            Text(
                scopeExplanation
            )
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
                    .accessibilityLabel(String(format: String(localized: "Connection change failed: %@"), errorMessage))
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.connectionID == nil ? String(localized: "Register") : String(localized: "Save")) {
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
            return String(localized: "This grant expired. Select an available target to renew access.")
        }
        guard currentTargetVersion != reviewed.targetVersion else { return nil }
        return String(
            localized:
                "This grant expired because the target incarnation changed. Saving refreshes it to the selected pane's current target."
        )
    }

    private var selectedExactPaneID: Binding<UUID?> {
        Binding(
            get: { draft.selectedPaneIDs.first },
            set: { draft.selectedPaneIDs = $0.map { [$0] } ?? [] }
        )
    }

    private var scopeExplanation: String {
        switch draft.scopeKind {
        case .currentTarget:
            String(localized: "This grant expires when the selected pane's target incarnation changes.")
        case .panes:
            String(localized: "Persistent pane grants follow selected panes across ordinary status changes.")
        case .workspaces:
            String(localized: "Persistent workspace grants include panes added to selected workspaces later.")
        }
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
