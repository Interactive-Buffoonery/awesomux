import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct AgentsSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var actionResults: [AgentIntegrationInstallProvider: AgentIntegrationSettingsActionResult] = [:]
    @State private var actionErrors: [AgentIntegrationInstallProvider: String] = [:]
    @State private var draftSetups: [AgentIntegrationInstallProvider: AgentIntegrationSetup] = [:]
    @FocusState private var focusedField: AgentIntegrationSettingsFocusedField?

    // The CLI-driven providers (Claude Code, Codex) use a separate, stateful view
    // model and their own draft keyspace, distinct from the file-drop providers
    // above; they never share the install machinery (the guard test pins that).
    @State private var pluginViewModel = AgentPluginSettingsViewModel()
    @State private var pluginDraftSetups: [AgentPluginProvider: AgentIntegrationSetup] = [:]
    @State private var pluginTasks: [AgentPluginProvider: Task<Void, Never>] = [:]
    @State private var pluginTaskIDs: [AgentPluginProvider: UUID] = [:]

    private let integrationViewModel = AgentIntegrationSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: "Permissions",
                subtitle: "How awesoMux handles tool-use prompts from coding agents."
            ) {
                SettingsField(
                    label: "Permission posture",
                    hint: "Applies to new agent sessions.",
                    isFirst: true
                ) {
                    SettingsSegmented(
                        options: postureOptions,
                        selection: appSettingsStore.agents.binding(\.permissionPosture)
                    )
                    // Group label + hint give orientation; the segments carry
                    // their own labels and the `.isSelected` trait. Phrased
                    // distinctly from the visible column label so VoiceOver
                    // doesn't announce the same string twice (the Terminal
                    // pane's clipboard-writes control does the same).
                    .accessibilityLabel(String(localized: "Agent permission posture"))
                    .accessibilityHint(
                        String(localized: "How awesoMux handles tool-use permission prompts. Applies to new agent sessions."))
                }

                SettingsField(
                    label: "Remember allowed tools",
                    hint: "Cache trust decisions per workspace once you have approved them.",
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Remember allowed tools", isOn: appSettingsStore.agents.binding(\.rememberToolTrust))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(
                index: 2,
                title: "Local status hooks",
                subtitle: "Provider-owned files that report identity and coarse runtime state."
            ) {
                let cardStates = integrationViewModel.cardStates(for: draftSetupsByProvider)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AgentIntegrationDisplayProvider.allCases, id: \.self) { display in
                        if let provider = display.installable, let state = cardStates[provider] {
                            AgentIntegrationSettingsCard(
                                state: state,
                                isEnabled: enabledBinding(provider: provider),
                                binaryPath: draftBinding(provider: provider, keyPath: \.binaryPath),
                                configHome: draftBinding(provider: provider, keyPath: \.configHome),
                                focusedField: $focusedField,
                                actionResult: actionResults[provider],
                                actionError: actionErrors[provider],
                                onCommit: { commitSetup(provider) },
                                onInstall: { install(provider) },
                                onUninstall: { uninstall(provider) }
                            )
                        } else if let pluginProvider = display.pluginProvider {
                            AgentPluginCard(
                                state: pluginViewModel.cardState(
                                    provider: pluginProvider,
                                    setup: pluginDraftSetup(for: pluginProvider)
                                ),
                                isEnabled: pluginEnabledBinding(provider: pluginProvider),
                                binaryPath: pluginDraftBinding(provider: pluginProvider, keyPath: \.binaryPath),
                                configHome: pluginDraftBinding(provider: pluginProvider, keyPath: \.configHome),
                                focusedField: $focusedField,
                                onCommit: { commitPluginSetup(pluginProvider) },
                                confirmation: { action in
                                    pluginViewModel.confirmation(
                                        for: action,
                                        provider: pluginProvider,
                                        setup: pluginDraftSetup(for: pluginProvider)
                                    )
                                },
                                onConfirmedAction: { action in
                                    performPluginAction(action, provider: pluginProvider)
                                },
                                onCheckStatus: { refreshPluginStatus(pluginProvider) },
                                onCancel: { cancelPluginTask(pluginProvider) }
                            )
                        }
                    }

                }
            }

            #if DEBUG
                SettingsSection(
                    index: 99,
                    title: "Debug",
                    subtitle: "Debug builds only. Forces the diagnostics disclosure with a sample payload."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AgentPluginProvider.allCases, id: \.self) { provider in
                            Toggle(
                                "Force sample diagnostics: \(provider.displayName)",
                                isOn: Binding(
                                    get: { pluginViewModel.isSampleDiagnosticsInjected(for: provider) },
                                    set: { _ in pluginViewModel.toggleSampleDiagnostics(for: provider) }
                                )
                            )
                            .toggleStyle(.switch)
                        }
                    }
                }
            #endif
        }
        .onAppear {
            syncDraftSetups(from: appSettingsStore.agentIntegrations.value)
            syncPluginDraftSetups(from: appSettingsStore.agentIntegrations.value)
        }
        .task {
            // Probe enabled CLI providers on appear (read-only; consent boundary).
            probeEnabledPluginProviders()
        }
        .onChange(of: controlActiveState) { _, newState in
            // Re-probe when the settings window regains key/active focus: after a
            // Codex install the card sits at needsReview; the user approves the hook
            // out-of-band, returns to this still-open pane, and nothing would refresh
            // the stale status without this (#6). A probe already in flight is left
            // alone by the busy-skip in the helper.
            if newState == .key {
                probeEnabledPluginProviders()
            }
        }
        .onChange(of: appSettingsStore.agentIntegrations.value) { oldIntegrations, integrations in
            if focusedField == nil {
                syncDraftSetups(from: integrations)
                syncPluginDraftSetups(from: integrations)
                reconcilePluginStatus(from: oldIntegrations, to: integrations)
            }
        }
        .onChange(of: focusedField) { oldField, newField in
            if let provider = oldField?.installable, oldField != newField {
                commitSetup(provider)
            } else if let provider = oldField?.pluginProvider, oldField != newField {
                commitPluginSetup(provider)
            }
        }
        .onDisappear {
            if let provider = focusedField?.installable {
                commitSetup(provider)
            } else if let provider = focusedField?.pluginProvider {
                commitPluginSetup(provider)
            }
            cancelPluginTasks()
        }
    }

    // MARK: - CLI-driven (Claude Code / Codex / Grok) plumbing

    private func pluginSetup(for provider: AgentPluginProvider) -> AgentIntegrationSetup {
        switch provider {
        case .claudeCode:
            appSettingsStore.agentIntegrations.value.claudeCode
        case .codex:
            appSettingsStore.agentIntegrations.value.codex
        case .grok:
            appSettingsStore.agentIntegrations.value.grok
        }
    }

    private func pluginDraftSetup(for provider: AgentPluginProvider) -> AgentIntegrationSetup {
        pluginDraftSetups[provider] ?? pluginSetup(for: provider)
    }

    private func syncPluginDraftSetups(from integrations: AgentIntegrationsConfig) {
        pluginDraftSetups = [
            .claudeCode: integrations.claudeCode,
            .codex: integrations.codex,
            .grok: integrations.grok,
        ]
    }

    private func pluginSetup(
        for provider: AgentPluginProvider,
        in integrations: AgentIntegrationsConfig
    ) -> AgentIntegrationSetup {
        switch provider {
        case .claudeCode:
            integrations.claudeCode
        case .codex:
            integrations.codex
        case .grok:
            integrations.grok
        }
    }

    /// Reconcile plugin card state when agent integrations change outside this pane
    /// (e.g. another settings surface or a config file edit). Clears stale status
    /// for disabled providers and re-probes enabled providers whose setup changed.
    private func reconcilePluginStatus(
        from oldIntegrations: AgentIntegrationsConfig,
        to newIntegrations: AgentIntegrationsConfig
    ) {
        for provider in AgentPluginProvider.allCases {
            let oldSetup = pluginSetup(for: provider, in: oldIntegrations)
            let newSetup = pluginSetup(for: provider, in: newIntegrations)
            guard oldSetup != newSetup else { continue }

            if !newSetup.enabled {
                pluginViewModel.clearCachedState(for: provider)
                continue
            }

            guard pluginTasks[provider] == nil else { continue }
            pluginViewModel.clearCachedState(for: provider)
            startPluginTask(provider: provider) { setup in
                await pluginViewModel.refreshStatus(provider: provider, setup: setup)
            }
        }
    }

    private func pluginDraftBinding(
        provider: AgentPluginProvider,
        keyPath: WritableKeyPath<AgentIntegrationSetup, String?>
    ) -> Binding<String> {
        Binding(
            get: { pluginDraftSetup(for: provider)[keyPath: keyPath] ?? "" },
            set: { value in
                // Path edits never persist before the opt-in toggle is on; the
                // field is disabled while off, and this guard is the backstop.
                guard pluginDraftSetup(for: provider).enabled else { return }
                var draft = pluginDraftSetup(for: provider)
                draft[keyPath: keyPath] = value
                pluginDraftSetups[provider] = draft
            }
        )
    }

    private func pluginEnabledBinding(provider: AgentPluginProvider) -> Binding<Bool> {
        Binding(
            get: { pluginDraftSetup(for: provider).enabled },
            set: { enabled in
                guard pluginTasks[provider] == nil else { return }
                var draft = pluginDraftSetup(for: provider)
                draft.enabled = enabled
                pluginDraftSetups[provider] = draft
                commitPluginSetup(provider)
                // Enabling is consent for read-only probes (decision 1); disabling
                // stops them. Refresh status accordingly.
                startPluginTask(provider: provider) { setup in
                    await pluginViewModel.refreshStatus(provider: provider, setup: setup)
                }
            }
        )
    }

    private func commitPluginSetup(_ provider: AgentPluginProvider) {
        let draft = pluginDraftSetup(for: provider)
        let normalized = AgentIntegrationSetup(
            enabled: draft.enabled,
            binaryPath: normalizedOptional(draft.binaryPath),
            configHome: normalizedOptional(draft.configHome)
        )
        pluginDraftSetups[provider] = normalized

        guard normalized != pluginSetup(for: provider) else { return }

        appSettingsStore.agentIntegrations.update { integrations in
            switch provider {
            case .claudeCode:
                integrations.claudeCode = normalized
            case .codex:
                integrations.codex = normalized
            case .grok:
                integrations.grok = normalized
            }
        }
    }

    /// Probe every enabled CLI provider that is not already busy. Skipping busy
    /// providers is load-bearing: `startPluginTask` cancels any in-flight task for
    /// the provider, so probing one mid-mutation would orphan that mutation — the
    /// exact non-cancellable-mutation invariant #8 protects. Auto-triggers (appear,
    /// focus) go through here; only idle providers get re-probed.
    private func probeEnabledPluginProviders() {
        for provider in AgentPluginProvider.allCases where pluginTasks[provider] == nil {
            if pluginDraftSetup(for: provider).enabled {
                startPluginTask(provider: provider) { setup in
                    await pluginViewModel.refreshStatus(provider: provider, setup: setup)
                }
            }
        }
    }

    /// Manual "Check status" from the card. Same busy-skip as the auto-probe: a
    /// mutation in flight is never interrupted by a status refresh.
    private func refreshPluginStatus(_ provider: AgentPluginProvider) {
        guard pluginTasks[provider] == nil else { return }
        guard pluginDraftSetup(for: provider).enabled else { return }
        startPluginTask(provider: provider) { setup in
            await pluginViewModel.refreshStatus(provider: provider, setup: setup)
        }
    }

    /// Cancel the in-flight task for a single provider. The card only exposes this
    /// while a probe is running (probes close their transport cleanly on cancel);
    /// a mutation offers no Cancel, so this never orphans a CLI write.
    private func cancelPluginTask(_ provider: AgentPluginProvider) {
        pluginTasks[provider]?.cancel()
        pluginTasks[provider] = nil
        pluginTaskIDs[provider] = nil
    }

    private func performPluginAction(_ action: AgentPluginAction, provider: AgentPluginProvider) {
        // A mutation must run to completion: the CLI op is not cancellation-aware,
        // so cancel-and-restart would discard a finished install's result while it
        // keeps running. The view model already refuses overlapping work and the
        // action controls disable while busy; this guard makes that invariant local
        // to the trigger rather than relying on every control to gate on isBusy.
        guard pluginTasks[provider] == nil else { return }
        commitPluginSetup(provider)
        startPluginTask(provider: provider) { setup in
            await pluginViewModel.perform(action: action, provider: provider, setup: setup)
        }
    }

    private func startPluginTask(
        provider: AgentPluginProvider,
        operation: @escaping (AgentIntegrationSetup) async -> Void
    ) {
        commitPluginSetup(provider)
        pluginTasks[provider]?.cancel()
        let taskID = UUID()
        pluginTaskIDs[provider] = taskID
        let task = Task { @MainActor in
            let setup = pluginDraftSetup(for: provider)
            await operation(setup)
            if pluginTaskIDs[provider] == taskID {
                pluginTasks[provider] = nil
                pluginTaskIDs[provider] = nil
            }
        }
        pluginTasks[provider] = task
    }

    private func cancelPluginTasks() {
        for task in pluginTasks.values {
            task.cancel()
        }
        pluginTasks = [:]
        pluginTaskIDs = [:]
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private var postureOptions: [SettingsSegmented<AgentConfig.PermissionPosture>.Option] {
        [
            .init(
                value: .askEveryTime,
                label: "Ask each time",
                accessibilityLabel: String(localized: "Ask before every agent tool use")
            ),
            .init(
                value: .rememberPerWorkspace,
                label: "Per workspace",
                accessibilityLabel: String(localized: "Remember approvals per workspace")
            ),
            .init(
                value: .trustKnownTools,
                label: "Trust known",
                accessibilityLabel: String(localized: "Trust known tools without asking")
            ),
        ]
    }

    private func setup(for provider: AgentIntegrationInstallProvider) -> AgentIntegrationSetup {
        switch provider {
        case .openCode:
            appSettingsStore.agentIntegrations.value.openCode
        case .pi:
            appSettingsStore.agentIntegrations.value.pi
        }
    }

    private func draftSetup(for provider: AgentIntegrationInstallProvider) -> AgentIntegrationSetup {
        draftSetups[provider] ?? setup(for: provider)
    }

    private var draftSetupsByProvider: [AgentIntegrationInstallProvider: AgentIntegrationSetup] {
        AgentIntegrationInstallProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = draftSetup(for: provider)
        }
    }

    private func draftBinding(
        provider: AgentIntegrationInstallProvider,
        keyPath: WritableKeyPath<AgentIntegrationSetup, String?>
    ) -> Binding<String> {
        Binding(
            get: { draftSetup(for: provider)[keyPath: keyPath] ?? "" },
            set: { value in
                // The toggle is the opt-in gate: path edits never persist before
                // it is on. The greyed field is `.disabled` so this normally
                // can't fire while off; rejecting the write here is the backstop
                // so the gate doesn't depend on the view alone.
                guard draftSetup(for: provider).enabled else {
                    return
                }
                var draft = draftSetup(for: provider)
                draft[keyPath: keyPath] = value
                draftSetups[provider] = draft
            }
        )
    }

    private func enabledBinding(provider: AgentIntegrationInstallProvider) -> Binding<Bool> {
        Binding(
            get: { draftSetup(for: provider).enabled },
            set: { enabled in
                var draft = draftSetup(for: provider)
                draft.enabled = enabled
                draftSetups[provider] = integrationViewModel.normalizedSetup(draft)
                commitSetup(provider)
            }
        )
    }

    private func syncDraftSetups(from integrations: AgentIntegrationsConfig) {
        draftSetups = [
            .openCode: integrations.openCode,
            .pi: integrations.pi,
        ]
    }

    private func commitSetup(_ provider: AgentIntegrationInstallProvider) {
        let committedSetup = integrationViewModel.normalizedSetup(draftSetup(for: provider))
        draftSetups[provider] = committedSetup

        guard committedSetup != setup(for: provider) else {
            return
        }

        appSettingsStore.agentIntegrations.update { integrations in
            switch provider {
            case .openCode:
                integrations.openCode = committedSetup
            case .pi:
                integrations.pi = committedSetup
            }
        }
        actionResults[provider] = nil
        actionErrors[provider] = nil
    }

    private func install(_ provider: AgentIntegrationInstallProvider) {
        commitSetup(provider)
        do {
            let result = try integrationViewModel.install(
                provider: provider,
                setup: draftSetup(for: provider)
            )
            actionResults[provider] = result
            actionErrors[provider] = nil
        } catch {
            actionResults[provider] = nil
            actionErrors[provider] = integrationViewModel.errorMessage(for: error)
        }
    }

    private func uninstall(_ provider: AgentIntegrationInstallProvider) {
        commitSetup(provider)
        do {
            _ = try integrationViewModel.uninstall(provider: provider)
            actionResults[provider] = nil
            actionErrors[provider] = nil
        } catch {
            actionResults[provider] = nil
            actionErrors[provider] = integrationViewModel.errorMessage(for: error)
        }
    }
}

enum AgentIntegrationSettingsFocusedField: Hashable {
    case binaryPath(AgentIntegrationDisplayProvider)
    case configHome(AgentIntegrationDisplayProvider)

    /// The install provider whose draft this field edits, or `nil` for a
    /// coming-soon placeholder (whose disabled fields never take focus).
    var installable: AgentIntegrationInstallProvider? {
        switch self {
        case .binaryPath(let display), .configHome(let display):
            display.installable
        }
    }

    var pluginProvider: AgentPluginProvider? {
        switch self {
        case .binaryPath(let display), .configHome(let display):
            display.pluginProvider
        }
    }
}

private struct AgentIntegrationSettingsCard: View {
    let state: AgentIntegrationSettingsCardState
    @Binding var isEnabled: Bool
    @Binding var binaryPath: String
    @Binding var configHome: String
    var focusedField: FocusState<AgentIntegrationSettingsFocusedField?>.Binding
    var actionResult: AgentIntegrationSettingsActionResult?
    var actionError: String?
    var onCommit: () -> Void
    var onInstall: () -> Void
    var onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // The full card stays present in every state so the layout never
            // jumps. Before opt-in the fields and action row are greyed and
            // read-only via `.disabled(!isEnabled)`, which also keeps their
            // bindings from firing a commit — the toggle is the only path that
            // writes config.
            fieldGrid
                .disabled(!isEnabled)
            pathSummary
            // The action row is not gated on `isEnabled`: a file installed before
            // the provider was turned off must stay removable without re-enabling.
            // The per-button `canInstall`/`canUninstall` flags carry the gate.
            actionRow
        }
        .padding(14)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                Text(state.subtitle)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
            }

            Spacer(minLength: 12)

            Toggle("Enable \(state.title)", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(isEnabled ? "Disable \(state.title)" : "Enable \(state.title)")
                .accessibilityLabel("\(state.title) integration")
                .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
                .accessibilityHint(
                    isEnabled
                        ? "Disabling stops awesoMux from checking paths or applying local status events"
                        : "Enabling allows checks and events; installing the provider plugin is a separate step")

            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.status.label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.aw.surface.chrome, in: RoundedRectangle(cornerRadius: AwRadius.pill))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.pill)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.title) status")
        .accessibilityValue(state.status.label)
        .accessibilityHint(state.status.detail)
    }

    private var fieldGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                pathEditor(
                    label: "Binary path",
                    accessibilityLabel: "\(state.title) binary path",
                    placeholder: state.binaryPlaceholder,
                    text: $binaryPath,
                    focusedField: .binaryPath(state.provider),
                    validation: state.binaryValidation
                )
                pathEditor(
                    label: "Config home",
                    accessibilityLabel: "\(state.title) config home",
                    placeholder: state.configHomePlaceholder,
                    text: $configHome,
                    focusedField: .configHome(state.provider),
                    validation: state.configHomeValidation
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                pathEditor(
                    label: "Binary path",
                    accessibilityLabel: "\(state.title) binary path",
                    placeholder: state.binaryPlaceholder,
                    text: $binaryPath,
                    focusedField: .binaryPath(state.provider),
                    validation: state.binaryValidation
                )
                pathEditor(
                    label: "Config home",
                    accessibilityLabel: "\(state.title) config home",
                    placeholder: state.configHomePlaceholder,
                    text: $configHome,
                    focusedField: .configHome(state.provider),
                    validation: state.configHomeValidation
                )
            }
        }
    }

    private func pathEditor(
        label: String,
        accessibilityLabel: String,
        placeholder: String,
        text: Binding<String>,
        focusedField: AgentIntegrationSettingsFocusedField,
        validation: AgentIntegrationPathValidation
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .accessibilityHidden(true)

            TextField(placeholder, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .awFont(AwFont.Mono.meta)
                .focused(self.focusedField, equals: focusedField)
                .onSubmit(onCommit)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(validation.displayText)

            Text(validation.displayText)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(validation.blockingMessage == nil ? Color.aw.text3 : Color.aw.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }

    private var pathSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentIntegrationSettingsPathRow(label: "Template", path: state.templatePath)
            AgentIntegrationSettingsPathRow(label: "Staged", path: state.renderedPath)
            // Surface the installed file whenever one is on disk, including the
            // off-but-installed case where the status badge reads "Off" and no
            // longer names the path.
            if let installedPath = state.installedPath {
                AgentIntegrationSettingsPathRow(label: "Installed", path: installedPath)
            }
            AgentIntegrationSettingsPathRow(
                label: "Destination",
                path: state.globalInstallPath
            )
        }
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onInstall) {
                Label(state.actionTitle, systemImage: state.actionSystemImage)
            }
            .disabled(!state.canInstall)
            .buttonStyle(.bordered)
            .help(installHelp)
            .accessibilityHint(installHelp)

            Button(action: onUninstall) {
                Label("Remove", systemImage: "trash")
            }
            .disabled(!state.canUninstall)
            .buttonStyle(.bordered)
            .help(removeHelp)
            .accessibilityHint(removeHelp)

            Text(actionMessage)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(actionError == nil ? Color.aw.text3 : Color.aw.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var installHelp: String {
        state.canInstall ? state.actionTitle : state.status.detail
    }

    private var removeHelp: String {
        state.canUninstall ? "Remove the installed awesoMux file" : "No installed file to remove"
    }

    private var actionMessage: String {
        if let actionError {
            return actionError
        }
        if actionResult != nil {
            return AgentIntegrationSettingsStatus.installed.detail
        }
        return state.status.detail
    }

    private var statusColor: Color {
        switch state.status {
        case .disabled:
            Color.aw.textFaint
        case .notInstalled:
            Color.aw.textFaint
        case .staged:
            Color.aw.sky
        case .installed:
            Color.aw.green
        case .updateAvailable, .installStateRepairRequired:
            Color.aw.peach
        case .blocked:
            Color.aw.red
        }
    }
}

private struct AgentIntegrationSettingsPathRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 72, alignment: .leading)
            Text(path)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(label) \(path)"))
    }
}
