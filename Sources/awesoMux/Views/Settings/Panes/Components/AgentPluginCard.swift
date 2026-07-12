import AwesoMuxConfig
import AppKit
import DesignSystem
import SwiftUI

// MARK: - AgentPluginCard

/// Settings card for a CLI-driven agent provider (Claude Code, Codex). Mirrors the
/// file-drop `AgentIntegrationSettingsCard` layout (header + status badge,
/// editable binary/config-home fields, path summary) and adds the CLI-specific
/// surfaces: rendered plugin source row, resolved helper path row, dist/ warning
/// banner, a status badge, an action row gated per `AgentPluginStatus`, a
/// confirmation sheet, and an expandable diagnostics disclosure on failure.
struct AgentPluginCard: View {
    let state: AgentPluginCardState
    @Binding var isEnabled: Bool
    @Binding var binaryPath: String
    @Binding var configHome: String
    var focusedField: FocusState<AgentIntegrationSettingsFocusedField?>.Binding
    var onCommit: () -> Void
    /// Asks for confirmation copy for the given action; the card stages it and
    /// shows the sheet. Returning the payload (not performing) keeps the card from
    /// owning the runner.
    var confirmation: (AgentPluginAction) -> AgentPluginConfirmation
    var onConfirmedAction: (AgentPluginAction) -> Void
    /// Triggers a manual read-only status re-probe (#6). Enabled whenever the
    /// provider is enabled and idle.
    var onCheckStatus: () -> Void
    /// Cancels an in-flight probe (#8). Only surfaced while a probe is running.
    var onCancel: () -> Void

    @State private var pendingConfirmation: AgentPluginConfirmation?
    @State private var diagnosticsExpanded = false
    @State private var didAppear = false
    @State private var lastAnnouncedStatusLabel: String?
    @State private var lastAnnouncedFailureSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fieldGrid
                .disabled(!isEnabled || state.isBusy)
            if let distWarning = state.distWarning {
                warningBanner(distWarning)
            }
            if let note = state.note {
                warningBanner(note)
            }
            pathSummary
            actionRow
            guidanceRow
            if state.diagnostics != nil {
                diagnosticsDisclosure
            }
        }
        .padding(14)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            didAppear = true
            lastAnnouncedStatusLabel = state.statusLabel
            lastAnnouncedFailureSummary = state.failureSummary
        }
        .onChange(of: state.statusLabel) { _, newValue in
            announceStatusChange(statusLabel: newValue, failureSummary: state.failureSummary)
        }
        .onChange(of: state.failureSummary) { _, newValue in
            announceStatusChange(statusLabel: state.statusLabel, failureSummary: newValue)
        }
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

    // MARK: Header

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
                .disabled(state.isBusy)
                .help(isEnabled ? "Disable \(state.title)" : "Enable \(state.title)")
                .accessibilityLabel("\(state.title) integration")
                .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
                .accessibilityHint(toggleAccessibilityHint)

            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.statusLabel)
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
        .accessibilityValue(state.statusLabel)
        .accessibilityHint(state.status.detail)
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
        .accessibilityLabel("Warning: \(message)")
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 10) {
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
                    // Only spin while a probe is actually running. A cancelled probe
                    // keeps the neutral "Checking" *text* (the status is genuinely
                    // unresolved until the next probe) but must not leave an animated
                    // spinner with nothing behind it.
                    if state.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text("Checking")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text3)
                }
                .accessibilityElement(children: .combine)
            } else if state.isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Spacer(minLength: 0)
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
                let detail = state.status.detail
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

    private var toggleAccessibilityHint: String {
        if state.isBusy {
            return "Unavailable while \(state.title) is checking or updating"
        }
        return isEnabled
            ? "Disabling stops awesoMux from probing this provider"
            : "Enabling allows status probes; installing the plugin is a separate step"
    }

    private func buttonHelp(title: String, enabled: Bool) -> String {
        enabled ? "\(title) \(state.title) status plugin" : "\(title) is unavailable for the current status"
    }

    private func errorText(_ summary: String) -> String {
        summary.hasPrefix("Error:") ? summary : "Error: \(summary)"
    }

    private func announceStatusChange(statusLabel: String, failureSummary: String?) {
        guard didAppear else { return }
        if lastAnnouncedStatusLabel == statusLabel,
           lastAnnouncedFailureSummary == failureSummary {
            return
        }
        lastAnnouncedStatusLabel = statusLabel
        lastAnnouncedFailureSummary = failureSummary

        let message: String
        let priority: NSAccessibilityPriorityLevel
        if let failureSummary {
            message = errorText(failureSummary)
            // A failure is more urgent than a routine status flip: raise it so
            // VoiceOver interrupts rather than queueing it behind other chatter.
            priority = .high
        } else {
            priority = .medium
            let detail = state.status.detail
            // Speak operator guidance for any status that carries distinct detail
            // (needs review/repair/unsupported), not only needsReview — otherwise
            // VoiceOver only hears the short badge label on status flips.
            if !detail.isEmpty, detail != statusLabel {
                message = "\(state.title) status: \(statusLabel). \(detail)"
            } else {
                message = "\(state.title) status: \(statusLabel)."
            }
        }

        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }

    private var statusColor: Color {
        switch state.status {
        case .notConfigured, .notInstalled, .disabled:
            Color.aw.textFaint
        case .enabled:
            Color.aw.green
        case .needsReview:
            Color.aw.peach
        case .needsRepair, .unsupported:
            Color.aw.red
        }
    }
}
