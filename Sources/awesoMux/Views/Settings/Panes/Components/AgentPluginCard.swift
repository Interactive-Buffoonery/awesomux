import AwesoMuxConfig
import AppKit
import DesignSystem
import SwiftUI

// MARK: - AgentPluginCard

/// Settings card for a CLI-driven agent provider (Claude Code, Codex). Mirrors the
/// file-drop `AgentIntegrationSettingsCard` layout (header + status badge,
/// editable binary/config-home fields, path summary) and adds the CLI-specific
/// surfaces: rendered plugin source row, resolved helper path row, dist/ warning
/// banner, and one `AgentPluginFolderSection` per config folder.
struct AgentPluginCard: View {
    /// The config field's folder; provider-wide fields come from it.
    let state: AgentPluginCardState
    let folders: [AgentPluginCardState]
    /// "Installed in N of M folders" once more than one folder is listed.
    let installSummary: String?
    var enabledSetupCount: Int = 0
    @Binding var isEnabled: Bool
    @Binding var binaryPath: String
    @Binding var configHome: String
    var focusedField: FocusState<AgentIntegrationSettingsFocusedField?>.Binding
    var onCommit: () -> Void
    /// Asks for confirmation copy for the given folder and action; the section
    /// stages it and shows the sheet. Returning the payload (not performing)
    /// keeps the card from owning the runner.
    var confirmation: (AgentPluginTarget, AgentPluginAction) -> AgentPluginConfirmation
    var onConfirmedAction: (AgentPluginTarget, AgentPluginAction) -> Void
    /// Triggers a manual read-only status re-probe of one folder (#6).
    var onCheckStatus: (AgentPluginTarget) -> Void
    /// Cancels an in-flight probe (#8). Only surfaced while a probe is running.
    var onCancel: () -> Void
    var onAddFolder: (String) -> Void
    var onForgetFolder: (AgentPluginTarget) -> Void

    var body: some View {
        AgentIntegrationDisclosureRow(
            title: state.title, subtitle: state.subtitle,
            needsAttention: folders.contains { $0.needsAttention }, enabledSetupCount: enabledSetupCount
        ) {
            statusBadge
        } toggle: {
            enableToggle
        } content: {
            fieldGrid
                .disabled(!isEnabled || state.isBusy)
            if let distWarning = state.distWarning {
                warningBanner(distWarning)
            }
            if let note = state.note {
                warningBanner(note)
            }
            pathSummary
            ForEach(folders, id: \.target) { folder in
                AgentPluginFolderSection(
                    state: folder,
                    isEnabled: isEnabled,
                    showsFolderHeader: folders.count > 1,
                    confirmation: { confirmation(folder.target, $0) },
                    onConfirmedAction: { onConfirmedAction(folder.target, $0) },
                    onCheckStatus: { onCheckStatus(folder.target) },
                    onCancel: onCancel,
                    onForget: { onForgetFolder(folder.target) }
                )
            }
            addFolderButton
        }
        .accessibilityElement(children: .contain)
        .onChange(of: folders) { previous, current in
            // The card survives disclosure collapse; folder content does not.
            for folder in current {
                guard let old = previous.first(where: { $0.target == folder.target }),
                    old.statusLabel != folder.statusLabel || old.failureSummary != folder.failureSummary
                else { continue }
                announceStatusChange(folder)
            }
        }
    }

    private func announceStatusChange(_ state: AgentPluginCardState) {
        let statusLabel = state.statusLabel
        let failureSummary = state.failureSummary
        // Several folders can change at once, so every announcement names the
        // provider and folder it is about.
        let provider = state.title
        let folder = state.folderPath
        let message: String
        let priority: NSAccessibilityPriorityLevel
        if let failureSummary {
            let detail =
                failureSummary.hasPrefix("Error:")
                ? String(failureSummary.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
                : failureSummary
            message = String(
                localized: "\(provider) error in \(folder): \(detail)",
                comment:
                    "VoiceOver announcement when an agent plugin check or action fails; arguments are the provider name, the config folder path, and the failure detail"
            )
            // A failure is more urgent than a routine status flip: raise it so
            // VoiceOver interrupts rather than queueing it behind other chatter.
            priority = .high
        } else {
            priority = .medium
            let detail = state.statusDetail
            // Speak operator guidance for any status that carries distinct detail
            // (needs review/repair/unsupported), not only needsReview — otherwise
            // VoiceOver only hears the short badge label on status flips.
            if !detail.isEmpty, detail != statusLabel {
                message = String(
                    localized: "\(provider) status in \(folder): \(statusLabel). \(detail)",
                    comment:
                        "VoiceOver announcement when an agent plugin folder status changes; arguments are the provider name, the config folder path, the status, and its guidance"
                )
            } else {
                message = String(
                    localized: "\(provider) status in \(folder): \(statusLabel).",
                    comment:
                        "VoiceOver announcement when an agent plugin folder status changes; arguments are the provider name, the config folder path, and the status"
                )
            }
        }

        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    private var addFolderButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            // Provider config folders such as ~/.claude-work are hidden.
            panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.prompt = String(localized: "Add", comment: "Confirm button for the agent config folder picker.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            onAddFolder(url.path)
        } label: {
            Label(
                String(localized: "Add folder…", comment: "Button that opens a picker for another agent config folder."),
                systemImage: "folder.badge.plus"
            )
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled || state.isBusy)
        .help(
            String(
                localized: "Manage the \(state.title) status plugin in another \(state.configHomeLabel) folder",
                comment: "Help for adding a config folder; arguments are the provider name and config home label.")
        )
        .accessibilityLabel(String(localized: "Add folder", comment: "Accessibility label for the agent config folder picker button."))
        .accessibilityHint(
            String(
                localized: "Manage the \(state.title) status plugin in another \(state.configHomeLabel) folder",
                comment: "Help for adding a config folder; arguments are the provider name and config home label."))
    }

    // MARK: Header

    @ViewBuilder private var statusBadge: some View {
        if let installSummary {
            AgentPluginStatusBadge(
                label: installSummary,
                color: Color.aw.textFaint,
                accessibilityLabel: String(
                    localized: "\(state.title) status",
                    comment: "Accessibility label for an agent plugin status badge; argument is the provider name."),
                accessibilityHint: ""
            )
        } else {
            AgentPluginStatusBadge(state: state)
        }
    }

    private var enableToggle: some View {
        Toggle("Enable \(state.title)", isOn: $isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(state.isBusy)
            .help(isEnabled ? "Disable \(state.title)" : "Enable \(state.title)")
            .accessibilityLabel("\(state.title) integration")
            .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
            .accessibilityHint(toggleAccessibilityHint)
    }

    private var toggleAccessibilityHint: String {
        if state.isBusy {
            return String(
                localized: "Unavailable while \(state.title) is checking or updating",
                comment: "Accessibility hint for a busy agent integration toggle; argument is the provider name.")
        }
        return isEnabled
            ? String(
                localized: "Disabling stops awesoMux from probing this provider",
                comment: "Accessibility hint for an enabled agent integration toggle.")
            : String(
                localized: "Enabling allows status probes; installing the plugin is a separate step",
                comment: "Accessibility hint for a disabled agent integration toggle.")
    }

    // MARK: Fields

    private var fieldGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                binaryField
                configHomeField
            }
            VStack(alignment: .leading, spacing: 10) {
                binaryField
                configHomeField
            }
        }
    }

    private var binaryField: some View {
        pathEditor(
            label: "Binary path",
            accessibilityLabel: "\(state.title) binary path",
            placeholder: state.binaryPlaceholder,
            text: $binaryPath,
            focusedFieldValue: .binaryPath(AgentIntegrationDisplayProvider(state.provider))
        )
    }

    private var configHomeField: some View {
        pathEditor(
            label: state.configHomeLabel,
            accessibilityLabel: "\(state.title) \(state.configHomeLabel)",
            placeholder: state.configHomePlaceholder,
            text: $configHome,
            focusedFieldValue: .configHome(AgentIntegrationDisplayProvider(state.provider))
        )
    }

    private func pathEditor(
        label: String,
        accessibilityLabel: String,
        placeholder: String,
        text: Binding<String>,
        focusedFieldValue: AgentIntegrationSettingsFocusedField
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .accessibilityHidden(true)
            TextField(placeholder, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .awFont(AwFont.Mono.meta)
                .focused(focusedField, equals: focusedFieldValue)
                .onSubmit(onCommit)
                .accessibilityLabel(accessibilityLabel)
        }
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Path summary

    private var pathSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let renderedSourcePath = state.renderedSourcePath {
                pathRow(label: "Plugin source", path: renderedSourcePath)
            }
            if let helperPath = state.helperPath {
                pathRow(label: "Helper", path: helperPath)
            }
        }
    }

    private func pathRow(label: String, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 92, alignment: .leading)
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

    private func warningBanner(_ message: String) -> some View {
        AgentPluginWarningBanner(message: message)
    }
}

// MARK: - AgentPluginFolderSection

/// Status, actions, guidance, and diagnostics for one provider config folder.
/// Each folder keeps its own confirmation sheet.
struct AgentPluginFolderSection: View {
    let state: AgentPluginCardState
    let isEnabled: Bool
    let showsFolderHeader: Bool
    var confirmation: (AgentPluginAction) -> AgentPluginConfirmation
    var onConfirmedAction: (AgentPluginAction) -> Void
    var onCheckStatus: () -> Void
    var onCancel: () -> Void
    var onForget: () -> Void

    @State private var pendingConfirmation: AgentPluginConfirmation?
    @State private var diagnosticsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsFolderHeader {
                folderHeader
            }
            actionRow
            guidanceRow
            if state.diagnostics != nil {
                diagnosticsDisclosure
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: state.diagnostics) { _, _ in
            // A fresh (or cleared) diagnostic starts collapsed so a later failure
            // can't auto-reveal a different error's expanded contents.
            diagnosticsExpanded = false
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { payload in
            Button(confirmActionLabel(payload.action), role: confirmRole(payload.action)) {
                onConfirmedAction(payload.action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { payload in
            Text(confirmationMessage(payload))
        }
    }

    private var folderHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(Color.aw.text3)
                .accessibilityHidden(true)
            Text(verbatim: (state.folderPath as NSString).abbreviatingWithTildeInPath)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel(
                    String(
                        localized: "Folder \(state.folderPath)",
                        comment: "Accessibility label for an agent config folder; argument is its path."))
            Spacer(minLength: 8)
            if state.canForget {
                Button(action: onForget) {
                    Label(
                        String(localized: "Stop managing", comment: "Button to forget an additional agent config folder."),
                        systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy)
                .help(
                    String(
                        localized: "Remove this folder from the list. Remove the plugin first to uninstall it.",
                        comment: "Help for forgetting an agent config folder without uninstalling its plugin.")
                )
                .accessibilityLabel(
                    String(
                        localized: "Stop managing folder", comment: "Accessibility label for forgetting an additional agent config folder.")
                )
                .accessibilityHint(
                    String(
                        localized: "Removes this folder from the list without changing it",
                        comment: "Accessibility hint for forgetting an additional agent config folder."))
            }
            AgentPluginStatusBadge(state: state)
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        AgentActionFlowLayout(spacing: 10) {
            actionButton("Enable", systemImage: "square.and.arrow.down", action: .enableOrInstall, enabled: state.allowsEnable)
            actionButton("Repair", systemImage: "arrow.clockwise", action: .repair, enabled: state.allowsRepair)
            actionButton("Disable", systemImage: "pause.circle", action: .disable, enabled: state.allowsDisable)
            actionButton("Remove", systemImage: "trash", action: .uninstall, enabled: state.allowsUninstall)
            checkStatusButton
            if state.canCancel {
                cancelButton
            }
            if state.isCheckingInitialStatus {
                HStack(spacing: 6) {
                    // Only spin while a probe is actually running. A queued or
                    // cancelled folder keeps the neutral "Checking" *text* (the status
                    // is genuinely unresolved until the next probe) but must not show
                    // an animated spinner with nothing behind it.
                    if state.inflightOp != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text("Checking")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text3)
                }
                .accessibilityElement(children: .combine)
            } else if state.inflightOp != nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: AgentPluginAction,
        enabled: Bool
    ) -> some View {
        Button {
            pendingConfirmation = confirmation(action)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!enabled)
        .buttonStyle(.bordered)
        .help(buttonHelp(title: title, enabled: enabled))
        // Pin the name explicitly: if the `Label` ever collapses to icon-only
        // (width-constrained row, larger text), the SF Symbol carries no
        // guaranteed accessible name and the button would go unnamed.
        .accessibilityLabel(title)
        .accessibilityHint(buttonHelp(title: title, enabled: enabled))
    }

    private var checkStatusButton: some View {
        // Enabled whenever the provider is on and nothing is in flight. Unlike the
        // mutating buttons it is not gated on status: a re-probe is always valid,
        // and it is the manual escape for a stale "Needs review" after an
        // out-of-band approval (#6).
        let enabled = isEnabled && !state.isBusy
        return Button(action: onCheckStatus) {
            Label("Check status", systemImage: "arrow.clockwise.circle")
        }
        .disabled(!enabled)
        .buttonStyle(.bordered)
        .help(enabled ? "Re-check \(state.title) status" : "Unavailable while \(state.title) is disabled or working")
        .accessibilityLabel("Check status")
        .accessibilityHint(enabled ? "Re-check \(state.title) status" : "Unavailable while \(state.title) is disabled or working")
    }

    private var cancelButton: some View {
        // Only shown while a probe is in flight (state.canCancel). A probe closes
        // its transport cleanly on cancel; mutations expose no Cancel because the
        // CLI op is not cancellation-aware (#8).
        Button(action: onCancel) {
            Label("Cancel check", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
        .help("Stop checking \(state.title) status")
        .accessibilityLabel("Cancel check")
        .accessibilityHint("Stop checking \(state.title) status")
    }

    private var guidanceRow: some View {
        Group {
            if let summary = state.failureSummary {
                Text(errorText(summary))
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let guidance = state.guidance {
                Text(guidance)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // A status whose detail is empty (e.g. an opaque underlying error)
                // would otherwise render a blank row under the badge; fall back to
                // the status label so there is always a visible explanation.
                let detail = state.statusDetail
                Text(detail.isEmpty ? state.statusLabel : detail)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnosticsDisclosure: some View {
        if let diagnostics = state.diagnostics {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if !diagnostics.summary.isEmpty {
                        Text(verbatim: diagnostics.summary)
                            .awFont(AwFont.UI.meta)
                            .foregroundStyle(Color.aw.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Diagnostics summary: \(diagnostics.summary)")
                    }
                    Text(verbatim: "\(diagnostics.executablePath) \(diagnostics.args.joined(separator: " "))")
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text3)
                        .textSelection(.enabled)
                        .accessibilityLabel("Command run: \(diagnostics.executablePath) \(diagnostics.args.joined(separator: " "))")
                    if let exitCode = diagnostics.exitCode {
                        Text(verbatim: "Command exited with status \(exitCode)")
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.text3)
                            .accessibilityLabel("Exit status: \(exitCode)")
                    }
                    if !diagnostics.stderr.isEmpty {
                        Text(verbatim: diagnostics.stderr)
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Standard error output: \(diagnostics.stderr)")
                    }
                    if !diagnostics.stdout.isEmpty {
                        Text(verbatim: diagnostics.stdout)
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Standard output: \(diagnostics.stdout)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Text("Diagnostics")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
            }
        }
    }

    // MARK: Confirmation plumbing

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private func confirmActionLabel(_ action: AgentPluginAction) -> String {
        switch action {
        case .enableOrInstall: "Install"
        case .repair: "Repair"
        case .disable: "Disable"
        case .uninstall: "Remove"
        }
    }

    private func confirmRole(_ action: AgentPluginAction) -> ButtonRole? {
        action == .uninstall ? .destructive : nil
    }

    private func confirmationMessage(_ payload: AgentPluginConfirmation) -> String {
        var lines = ["Runs \(payload.executablePath):"]
        lines.append(contentsOf: payload.commandLines.map { "  \($0)" })
        if !payload.configTargets.isEmpty {
            lines.append("Affects: \(payload.configTargets.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func buttonHelp(title: String, enabled: Bool) -> String {
        enabled ? "\(title) \(state.title) status plugin" : "\(title) is unavailable for the current status"
    }

    private func errorText(_ summary: String) -> String {
        summary.hasPrefix("Error:") ? summary : "Error: \(summary)"
    }
}

// MARK: - Shared pieces

struct AgentPluginWarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.aw.peach)
                .accessibilityHidden(true)
            Text(message)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aw.surface.chrome, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        // The triangle icon and peach tint carry the "caution" signal visually;
        // name the role so VoiceOver doesn't read it as ordinary body text.
        .accessibilityLabel(
            String(localized: "Warning: \(message)", comment: "Accessibility label for an agent plugin warning; argument is its message."))
    }
}

struct AgentPluginStatusBadge: View {
    let label: String
    let color: Color
    let accessibilityLabel: String
    let accessibilityHint: String

    init(label: String, color: Color, accessibilityLabel: String, accessibilityHint: String) {
        self.label = label
        self.color = color
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
    }

    init(state: AgentPluginCardState) {
        self.init(
            label: state.statusLabel,
            color: Self.color(for: state.status),
            accessibilityLabel: String(
                localized: "\(state.title) status",
                comment: "Accessibility label for an agent plugin status badge; argument is the provider name."),
            accessibilityHint: state.statusDetail
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(label)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(label)
        .accessibilityHint(accessibilityHint)
    }

    private static func color(for status: AgentPluginStatus) -> Color {
        switch status {
        case .notConfigured, .notInstalled, .disabled:
            Color.aw.textFaint
        case .enabled:
            Color.aw.green
        case .needsReview, .updateAvailable:
            Color.aw.peach
        case .needsRepair, .unsupported:
            Color.aw.red
        }
    }
}
