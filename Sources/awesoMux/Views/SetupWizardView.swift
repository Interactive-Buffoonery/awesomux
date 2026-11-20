import AwesoMuxConfig
import DesignSystem
import SwiftUI

// MARK: - Steps

enum SetupWizardStep: Hashable, CaseIterable {
    case welcome
    case appearance
    case sidebar
    case agents
    case ready

    /// The welcome step only asks whether to keep a Ghostty background, so it
    /// exists only when there is a Ghostty config to keep.
    static func steps(hasGhosttyConfig: Bool) -> [SetupWizardStep] {
        hasGhosttyConfig ? allCases : allCases.filter { $0 != .welcome }
    }
}

// MARK: - Panel root

/// Panel root. Reads `currentStep` inside a `body` so Observation tracks it.
/// It must stay a bare pass-through: the controller measures `SetupWizardPage`
/// directly and pins the panel to that size.
struct SetupWizardView: View {
    let controller: FirstRunTourController
    let store: AppSettingsStore

    var body: some View {
        SetupWizardPage(
            controller: controller,
            store: store,
            step: controller.currentStep,
            presentationToken: controller.presentationToken)
    }
}

// MARK: - Page

struct SetupWizardPage: View {
    let controller: FirstRunTourController
    let store: AppSettingsStore
    let step: SetupWizardStep
    var presentationToken = 0
    /// Lays content out at its natural height, without the scroll view the
    /// live panel uses once the panel is capped to the screen.
    var isMeasuring = false

    @Environment(\.awAccent) private var accentResolver
    @AccessibilityFocusState private var stepFocused: Bool

    private var steps: [SetupWizardStep] { controller.steps }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var isFirstStep: Bool { index == 0 }
    private var isLastStep: Bool { index >= steps.count - 1 }

    private var stepLabel: String {
        String(
            localized: "Step \(index + 1) of \(steps.count)",
            comment: "Welcome tour step indicator. First argument is the current step, second is the total.")
    }

    // Focus rings draw outside their control; this inset keeps them inside the
    // scroll view's clip. The outer padding gives the same amount back.
    private static let focusInset: CGFloat = 3

    var body: some View {
        // Same frame as the tour it replaced: section gap above the footer,
        // panel padding all round (the focus inset is given back below).
        VStack(alignment: .leading, spacing: AwSpacing.sectionGap - Self.focusInset) {
            if isMeasuring {
                content
            } else {
                ScrollView {
                    content
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            footer
                .padding([.horizontal, .bottom], Self.focusInset)
        }
        .padding(AwSpacing.panelPadding - Self.focusInset)
        // Vertical traffic-light clearance: the panel shows standard window
        // buttons and the content starts at the top edge.
        .padding(.top, AwSpacing.titlebar - AwSpacing.panelPadding)
        .frame(width: 420, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .fill(Color.aw.surface.window)
                .awShadow(.sheet, rendering: .composited)
        }
        .clipShape(RoundedRectangle(cornerRadius: AwRadius.window))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        // Unlabelled container: the panel title already names the window.
        .accessibilityElement(children: .contain)
        // The panel and page outlive both presentation and page turns, so
        // focus is driven by both values rather than a one-shot flag.
        .onChange(of: [presentationToken, index], initial: true) { _, _ in
            focusStep()
        }
    }

    private var content: some View {
        stepContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.focusInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(stepLabel)
            .accessibilityFocused($stepFocused)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            SetupWizardWelcomeStep(store: store)
        case .appearance:
            SetupWizardAppearanceStep(store: store, hasGhosttyConfig: controller.hasGhosttyConfig)
        case .sidebar:
            SetupWizardSidebarStep(store: store)
        case .agents:
            if let agents = controller.agents {
                SetupWizardAgentsStep(
                    store: store,
                    agents: agents,
                    notifications: controller.notificationAuthorization,
                    isMeasuring: isMeasuring,
                    requestNotifications: { controller.requestNotifications() })
            }
        case .ready:
            SetupWizardReadyStep(store: store)
        }
    }

    /// Cleared first so a re-focus is a real transition, then deferred a turn
    /// so the element exists in the accessibility tree before focus lands.
    private func focusStep() {
        guard !isMeasuring else { return }
        stepFocused = false
        Task { @MainActor in
            await Task.yield()
            stepFocused = true
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            stepIndicator

            Spacer(minLength: 12)

            // Nothing to skip on the last step: Skip and the primary button
            // would both end the wizard.
            if !isLastStep {
                Button(String(localized: "Skip", comment: "Welcome tour button dismissing the tour")) {
                    controller.dismissByUser()
                }
                .awButtonStyle(.link)
            }

            Button(String(localized: "Back", comment: "Welcome tour button returning to the previous beat")) {
                controller.retreat()
            }
            .awButtonStyle(.ghost)
            .disabled(isFirstStep)

            Button(
                isLastStep
                    ? String(
                        localized: "Create first workspace",
                        comment: "Setup wizard button on the last step that closes the wizard and creates a workspace")
                    : String(localized: "Continue", comment: "Setup wizard button advancing to the next step")
            ) {
                if isLastStep { controller.createFirstWorkspace() } else { controller.advance() }
            }
            .awButtonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// The text carries the position (WCAG 1.4.1); the dots are decoration.
    private var stepIndicator: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Color.aw.accentOnChrome(accentResolver.accent) : Color.aw.textFaint)
                        .frame(width: 5, height: 5)
                }
            }

            Text(stepLabel)
                .awFont(AwFont.UI.meta)
                // Primary text: `text2` is under 4.5:1 on the Latte window.
                .foregroundStyle(Color.aw.text)
        }
        // The step group already announces "Step N of M".
        .accessibilityHidden(true)
    }
}

// MARK: - Steps

private struct SetupWizardWelcomeStep: View {
    let store: AppSettingsStore

    private var mode: AppearanceConfig.TerminalBackgroundMode {
        store.appearance.value.terminalBackgroundMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DaveMark().daveMarkGap()
            WizardKicker(text: SetupWizardCopy.welcomeTitle)
            WizardRow(isFirst: true) {
                VStack(alignment: .leading, spacing: 8) {
                    WizardLabel(
                        title: String(
                            localized: "Terminal background",
                            comment: "Setup wizard label for the terminal background choice"))
                    SettingsSegmented(
                        options: [
                            .init(
                                value: .ghostty,
                                label: String(
                                    localized: "Keep my Ghostty background",
                                    comment: "Setup wizard option that keeps the Ghostty config's terminal background")),
                            .init(
                                value: .catppuccinTheme,
                                label: String(
                                    localized: "Use an awesoMux theme",
                                    comment: "Setup wizard option that uses an awesoMux terminal theme")),
                        ],
                        // A custom background matches neither option, so
                        // neither shows selected until the user picks one.
                        selection: store.appearance.binding(\.terminalBackgroundMode),
                        expandsToFill: true)
                    TerminalBackgroundPreview(
                        backgroundHex: SetupWizardCopy.themeBackground(store: store, colorScheme: nil),
                        usesGhosttyConfig: mode == .ghostty)
                }
            }
        }
    }
}

private struct SetupWizardAppearanceStep: View {
    let store: AppSettingsStore
    let hasGhosttyConfig: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var appearance: AppearanceConfig { store.appearance.value }

    private var showsTerminalTheme: Bool {
        !hasGhosttyConfig || appearance.terminalBackgroundMode != .ghostty
    }

    private var accent: Binding<AwAccent> {
        Binding(
            get: { AwAccent(configAccent: appearance.accent) },
            set: { newValue in store.appearance.update { $0.accent = newValue.configAccent } }
        )
    }

    private var terminalTheme: Binding<String> {
        Binding(
            get: {
                // Same trim/lowercase normalization as the catalog, matching
                // the Appearance pane's picker.
                let normalized = appearance.terminalThemeID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return normalized == TerminalThemeCatalog.selenizedID
                    ? TerminalThemeCatalog.selenizedID
                    : TerminalThemeCatalog.catppuccinID
            },
            set: { selectedID in
                store.appearance.update {
                    $0.terminalThemeID = selectedID == TerminalThemeCatalog.catppuccinID ? nil : selectedID
                    $0.terminalBackgroundMode = .catppuccinTheme
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Without a Ghostty config there is no welcome step, so this one
            // opens the wizard and carries its header.
            if hasGhosttyConfig {
                WizardKicker(
                    text: String(localized: "Appearance", comment: "Setup wizard heading for the appearance step"))
            } else {
                DaveMark().daveMarkGap()
                WizardKicker(text: SetupWizardCopy.welcomeTitle)
            }

            VStack(alignment: .leading, spacing: 0) {
                WizardRow(isFirst: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        WizardLabel(title: String(localized: "Theme", comment: "Setup wizard label for the app theme"))
                        SettingsThemePreview(selection: store.appearance.binding(\.theme), variant: .grid)
                    }
                }
                WizardRow {
                    HStack(spacing: 12) {
                        WizardLabel(title: String(localized: "Accent", comment: "Setup wizard label for the accent color"))
                        SettingsSwatchGrid(selection: accent)
                            // Four 30pt swatches and three 12pt gaps on one line.
                            .frame(width: 156)
                    }
                }
                if showsTerminalTheme {
                    WizardRow {
                        HStack(spacing: 12) {
                            WizardLabel(
                                title: String(
                                    localized: "Terminal theme", comment: "Label for the terminal color theme picker"))
                            AppDropdownPicker(
                                title: String(
                                    localized: "Terminal theme", comment: "Label for the terminal color theme picker"),
                                selection: terminalTheme,
                                options: [
                                    (
                                        TerminalThemeCatalog.catppuccinID,
                                        String(
                                            localized: "Catppuccin",
                                            comment: "Name of the Catppuccin terminal color theme")
                                    ),
                                    (
                                        TerminalThemeCatalog.selenizedID,
                                        String(
                                            localized: "Selenized",
                                            comment: "Name of the Selenized terminal color theme")
                                    ),
                                ]
                            )
                            .fixedSize()
                            .accessibilityLabel("Terminal theme")
                        }
                    }
                }
                WizardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        WizardLabel(
                            title: String(localized: "Preview", comment: "Setup wizard label for the terminal preview"))
                        TerminalBackgroundPreview(
                            backgroundHex: SetupWizardCopy.themeBackground(store: store, colorScheme: colorScheme),
                            usesGhosttyConfig: !showsTerminalTheme)
                    }
                }
            }
        }
    }
}

private struct SetupWizardSidebarStep: View {
    let store: AppSettingsStore

    private var newWorkspace: KeyBinding {
        KeyboardShortcutCatalog.resolved(KeyboardShortcutCatalog.newWorkspace, keyboard: store.keyboard.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardBeat(
                heading: String(localized: "workspaces, not tabs", comment: "Welcome tour heading for the workspaces beat"),
                visible: String(
                    localized:
                        "Start with a workspace — a shell with its own name in the sidebar. Press \(newWorkspace.displaySymbol) to make one. Use it like any terminal. No agent required.",
                    comment:
                        "Welcome tour beat one. Argument is the New Workspace keyboard shortcut as symbols, e.g. ⌘N."),
                spoken: String(
                    localized:
                        "Start with a workspace — a shell with its own name in the sidebar. Press \(newWorkspace.spokenForm) to make one. Use it like any terminal. No agent required.",
                    comment:
                        "Spoken form of beat one. Argument is the New Workspace shortcut spelled out, e.g. Command N."))

            WizardBeat(
                heading: String(localized: "the sidebar", comment: "Welcome tour heading for the sidebar beat"),
                visible: String(
                    localized:
                        "Drag workspaces into groups to keep a project together. Split a workspace for terminals side by side — its panes still share one sidebar row. Go wild!",
                    comment: "Welcome tour beat two, explaining the sidebar and panes."))

            VStack(alignment: .leading, spacing: 0) {
                WizardRow(isFirst: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        WizardLabel(
                            title: String(localized: "Position", comment: "Setup wizard label for the sidebar position"))
                        SidebarPositionCards(selection: store.appearance.binding(\.sidebarPosition))
                    }
                }
                WizardRow {
                    HStack(spacing: 12) {
                        WizardLabel(
                            title: String(
                                localized: "Open on", comment: "Setup wizard label for the sidebar shown at launch"))
                        SettingsSegmented(
                            options: [
                                .init(
                                    value: AppearanceConfig.SidebarMode.workspaces,
                                    label: String(localized: "Workspaces", comment: "Sidebar mode option")),
                                .init(
                                    value: AppearanceConfig.SidebarMode.agents,
                                    label: String(localized: "Agents", comment: "Sidebar mode option")),
                            ],
                            selection: store.appearance.binding(\.defaultSidebar))
                    }
                }
                WizardRow {
                    WizardSwitch(
                        title: String(
                            localized: "Compact rows", comment: "Setup wizard switch for sidebar compact mode"),
                        isOn: store.general.binding(\.sidebarCompactMode))
                }
                WizardRow {
                    WizardSwitch(
                        title: String(
                            localized: "Move workspaces that need you to the top",
                            comment: "Setup wizard switch that promotes workspaces needing input in the sidebar"),
                        isOn: store.appearance.binding(\.promoteWorkspacesNeedingInput))
                }
            }
        }
    }
}

private struct SetupWizardAgentsStep: View {
    let store: AppSettingsStore
    let agents: SetupWizardAgentsModel
    let notifications: NotificationAuthorizationModel
    let isMeasuring: Bool
    let requestNotifications: () -> Void

    private var notificationStatus: String {
        switch notifications.status {
        case .unknown:
            String(localized: "Checking…", comment: "Setup wizard notification permission status while it loads")
        case .notDetermined:
            String(localized: "Not requested yet", comment: "Setup wizard notification permission status")
        case .authorized:
            String(localized: "Allowed", comment: "Setup wizard notification permission status")
        case .denied:
            String(localized: "Denied", comment: "Setup wizard notification permission status")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardBeat(
                heading: String(localized: "agents, watched", comment: "Welcome tour heading for the agents beat"),
                visible: String(
                    localized:
                        "Run an agent you've already installed, such as Claude Code or Codex. Set up its integration below for more reliable activity updates. Allow notifications for alerts while you're in another app; delivery follows your notification settings.",
                    comment: "Setup wizard agents step, introducing agent awareness and notifications."))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentIntegrationDisplayProvider.allCases, id: \.self) { display in
                    if display != AgentIntegrationDisplayProvider.allCases.first {
                        Divider().overlay(Color.aw.border)
                    }
                    SetupWizardAgentRow(display: display, agents: agents)
                }
            }
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button).stroke(Color.aw.border, lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 0) {
                WizardRow(isFirst: true) {
                    HStack(spacing: 12) {
                        WizardLabel(
                            title: String(
                                localized: "Notifications", comment: "Setup wizard label for notification permission"),
                            hint: notificationStatus)
                        // macOS shows its prompt once per app; after that the
                        // choice lives in System Settings.
                        if notifications.status == .notDetermined {
                            Button(
                                String(
                                    localized: "Allow…",
                                    comment: "Setup wizard button that shows the macOS notification prompt"),
                                action: requestNotifications
                            )
                            .awButtonStyle(.primary)
                        }
                    }
                }
                WizardRow {
                    WizardSwitch(
                        title: String(
                            localized: "Notify when an agent needs input",
                            comment: "Setup wizard switch for needs-input notifications"),
                        isOn: store.notifications.binding(\.notifyOnNeedsAttention)
                    )
                    .disabled(notifications.status != .authorized)
                }
            }
        }
        .onAppear {
            guard !isMeasuring else { return }
            notifications.refresh()
            agents.refreshAll()
        }
    }
}

private struct SetupWizardReadyStep: View {
    let store: AppSettingsStore

    private struct Row: Identifiable {
        let action: String
        let visible: String
        let spoken: String
        var id: String { action }
    }

    private var rows: [Row] {
        let keyboard = store.keyboard.value
        func row(_ binding: KeyBinding) -> Row {
            let resolved = KeyboardShortcutCatalog.resolved(binding, keyboard: keyboard)
            return Row(action: resolved.action, visible: resolved.displaySymbol, spoken: resolved.spokenForm)
        }
        let jumps = KeyboardShortcutCatalog.resolved(KeyboardShortcutCatalog.jumpWorkspaces, keyboard: keyboard)
        var result = [
            row(KeyboardShortcutCatalog.newWorkspace),
            row(KeyboardShortcutCatalog.splitRight),
            row(KeyboardShortcutCatalog.toggleCommandPalette),
        ]
        if let first = jumps.first, let last = jumps.last {
            result.append(
                Row(
                    action: String(
                        localized: "Jump to Workspace", comment: "Setup wizard shortcut row for jumping to workspaces 1 to 9"),
                    visible: "\(first.displaySymbol)–\(last.keyDisplay)",
                    spoken: String(
                        localized: "\(first.spokenForm) through \(last.keyDisplay)",
                        comment: "Spoken range of the jump-to-workspace shortcuts, e.g. Command 1 through 9")))
        }
        result += [
            row(KeyboardShortcutCatalog.toggleFloatingPanel),
            row(KeyboardShortcutCatalog.togglePopUpTerminal),
            row(KeyboardShortcutCatalog.showKeyboardCheatsheet),
        ]
        return result
    }

    var body: some View {
        let keyboard = store.keyboard.value
        let palette = KeyboardShortcutCatalog.resolved(KeyboardShortcutCatalog.toggleCommandPalette, keyboard: keyboard)
        let cheatsheet = KeyboardShortcutCatalog.resolved(
            KeyboardShortcutCatalog.showKeyboardCheatsheet, keyboard: keyboard)

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                WizardKicker(text: String(localized: "Your shortcuts", comment: "Setup wizard heading for the shortcut list"))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        WizardRow(isFirst: offset == 0) {
                            HStack(spacing: 12) {
                                WizardLabel(title: row.action)
                                KBD(row.visible)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.action), \(row.spoken)")
                        }
                    }
                }
            }

            WizardBeat(
                heading: String(
                    localized: "where everything else lives", comment: "Welcome tour heading for the closing beat"),
                visible: String(
                    localized:
                        "Find commands with \(palette.displaySymbol), or open the keyboard cheatsheet with \(cheatsheet.displaySymbol). The ? button in the sidebar footer brings this tour back.",
                    comment:
                        "Setup wizard closing step. Arguments are the command-palette and cheatsheet shortcuts as symbols."),
                spoken: String(
                    localized:
                        "Find commands with \(palette.spokenForm), or open the keyboard cheatsheet with \(cheatsheet.spokenForm). The question mark button in the sidebar footer brings this tour back.",
                    comment: "Spoken form of the setup wizard closing step. Arguments are those two shortcuts spelled out."))

            HStack(spacing: 10) {
                DaveMark(isSmall: true)
                Text(
                    String(
                        localized: "Go build something awesome…ux. (I'm an AI Goose, I did my best, sorry.) — D.A.V.E.",
                        comment: "Setup wizard sign-off; D.A.V.E. is the mascot.")
                )
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Agents

private struct SetupWizardAgentRow: View {
    let display: AgentIntegrationDisplayProvider
    let agents: SetupWizardAgentsModel

    @State private var pendingConfirmation: AgentPluginConfirmation?

    var body: some View {
        let isEnabled = agents.setup(for: display).enabled
        if let provider = display.pluginProvider {
            let state = agents.pluginState(provider)
            row(
                title: state.title, subtitle: state.subtitle, isEnabled: isEnabled, isBusy: state.isBusy,
                needsAttention: isEnabled && state.needsAttention
            ) {
                if isEnabled {
                    AgentPluginStatusBadge(state: state)
                    if state.allowsEnable {
                        installButton { pendingConfirmation = agents.confirmation(provider) }
                    }
                }
            } detail: {
                if isEnabled {
                    detailText(state.failureSummary ?? state.guidance ?? state.statusDetail)
                }
            }
            .confirmationDialog(
                pendingConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { _ in
                Button("Install") { agents.installPlugin(provider) }
                Button("Cancel", role: .cancel) {}
            } message: { payload in
                Text(payload.message)
            }
        } else if let provider = display.installable {
            let state = agents.installableState(provider)
            let error = agents.installErrors[provider]
            row(
                title: state.title, subtitle: state.subtitle, isEnabled: isEnabled, isBusy: false,
                needsAttention: isEnabled && error != nil
            ) {
                if isEnabled {
                    AgentPluginStatusBadge(
                        label: state.isAuthoritative
                            ? state.status.label
                            : String(
                                localized: "Checking…",
                                comment: "Agent integration status badge while a check is in flight"),
                        color: state.status.badgeColor,
                        accessibilityLabel: String(
                            localized: "\(state.title) status",
                            comment: "Accessibility label for an agent plugin status badge; argument is the provider name."),
                        accessibilityHint: state.status.detail)
                    if state.canInstall {
                        installButton { agents.install(provider) }
                    }
                }
            } detail: {
                if isEnabled {
                    detailText(error ?? state.status.detail)
                }
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        isEnabled: Bool,
        isBusy: Bool,
        needsAttention: Bool,
        @ViewBuilder status: () -> some View,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        AgentIntegrationDisclosureRow(
            title: title, subtitle: subtitle, needsAttention: needsAttention, enabledSetupCount: 0
        ) {
            status()
        } toggle: {
            // Enabling only opts in to status checks; Install is its own click.
            Toggle(
                isOn: Binding(
                    get: { isEnabled },
                    set: { agents.setEnabled($0, for: display) })
            ) {
                EmptyView()
            }
            .toggleStyle(AwToggleStyle())
            .disabled(isBusy)
            .help(isEnabled ? "Disable \(title)" : "Enable \(title)")
            .accessibilityLabel("\(title) integration")
            .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
        } content: {
            detail()
        }
    }

    private func installButton(action: @escaping () -> Void) -> some View {
        Button(String(localized: "Install", comment: "Setup wizard button installing an agent integration"), action: action)
            .awButtonStyle(.primary)
    }

    @ViewBuilder
    private func detailText(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Agents pane's integration plumbing, cut down to what the wizard shows:
/// one switch, one status, and Install per provider, without path editing.
@MainActor
@Observable
final class SetupWizardAgentsModel {
    @ObservationIgnored private let store: AppSettingsStore
    @ObservationIgnored private let integrationViewModel = AgentIntegrationSettingsViewModel()
    private let pluginViewModel = AgentPluginSettingsViewModel()
    private let cardModel = AgentIntegrationSettingsCardModel(
        viewModel: AgentIntegrationSettingsViewModel(),
        probeServices: { _ in AgentIntegrationProbeService() })
    private var pluginTasks: [AgentPluginProvider: (id: UUID, task: Task<Void, Never>, isProbe: Bool)] = [:]
    private(set) var installErrors: [AgentIntegrationInstallProvider: String] = [:]

    init(store: AppSettingsStore) {
        self.store = store
    }

    private static func keyPath(
        _ display: AgentIntegrationDisplayProvider
    ) -> WritableKeyPath<AgentIntegrationsConfig, AgentIntegrationSetup> {
        switch display {
        case .claudeCode: \.claudeCode
        case .codex: \.codex
        case .openCode: \.openCode
        case .pi: \.pi
        case .grok: \.grok
        case .antigravity: \.antigravity
        }
    }

    func setup(for display: AgentIntegrationDisplayProvider) -> AgentIntegrationSetup {
        store.agentIntegrations.value[keyPath: Self.keyPath(display)]
    }

    func setEnabled(_ enabled: Bool, for display: AgentIntegrationDisplayProvider) {
        // A CLI mutation is not cancellation-aware; never race it.
        if let provider = display.pluginProvider, pluginTasks[provider] != nil { return }
        var setup = setup(for: display)
        setup.enabled = enabled
        let committed = integrationViewModel.normalizedSetup(setup)
        store.agentIntegrations.update { $0[keyPath: Self.keyPath(display)] = committed }
        if let provider = display.pluginProvider {
            // Enabling is consent for read-only probes; a disabled probe clears status.
            probe(provider)
        } else if let provider = display.installable {
            installErrors[provider] = nil
            cardModel.refresh(provider: provider, setup: committed)
        }
    }

    // MARK: CLI plugins

    private func target(_ provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> AgentPluginTarget {
        // ponytail: primary config folder only; extra folders stay in Agents settings.
        pluginViewModel.targets(provider: provider, setup: setup)[0]
    }

    func pluginState(_ provider: AgentPluginProvider) -> AgentPluginCardState {
        let setup = setup(for: AgentIntegrationDisplayProvider(provider))
        return pluginViewModel.cardState(target: target(provider, setup: setup), setup: setup)
    }

    func confirmation(_ provider: AgentPluginProvider) -> AgentPluginConfirmation {
        let setup = setup(for: AgentIntegrationDisplayProvider(provider))
        return pluginViewModel.confirmation(
            for: .enableOrInstall, target: target(provider, setup: setup), setup: setup)
    }

    func installPlugin(_ provider: AgentPluginProvider) {
        runPluginTask(provider, isProbe: false) { model, target, setup in
            await model.perform(action: .enableOrInstall, target: target, setup: setup)
        }
    }

    private func probe(_ provider: AgentPluginProvider) {
        runPluginTask(provider, isProbe: true) { model, target, setup in
            await model.refreshStatus(target: target, setup: setup)
        }
    }

    private func runPluginTask(
        _ provider: AgentPluginProvider,
        isProbe: Bool,
        operation:
            @escaping @MainActor (AgentPluginSettingsViewModel, AgentPluginTarget, AgentIntegrationSetup) async
            -> Void
    ) {
        guard pluginTasks[provider] == nil else { return }
        let setup = setup(for: AgentIntegrationDisplayProvider(provider))
        let target = target(provider, setup: setup)
        let model = pluginViewModel
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation(model, target, setup)
            if self?.pluginTasks[provider]?.id == id {
                self?.pluginTasks[provider] = nil
            }
        }
        pluginTasks[provider] = (id, task, isProbe)
    }

    // MARK: File-drop integrations

    func installableState(_ provider: AgentIntegrationInstallProvider) -> AgentIntegrationSettingsCardState {
        cardModel.state(for: provider, setup: setup(for: AgentIntegrationDisplayProvider(provider)))
    }

    func install(_ provider: AgentIntegrationInstallProvider) {
        let setup = setup(for: AgentIntegrationDisplayProvider(provider))
        do {
            _ = try integrationViewModel.install(provider: provider, setup: setup)
            installErrors[provider] = nil
        } catch {
            installErrors[provider] = integrationViewModel.errorMessage(for: error)
        }
        cardModel.refreshAfterMutation(provider: provider, setup: setup)
    }

    // MARK: Lifecycle

    /// Forced: an unchanged setup says nothing about unchanged files.
    func refreshAll() {
        for provider in AgentPluginProvider.allCases where setup(for: AgentIntegrationDisplayProvider(provider)).enabled {
            probe(provider)
        }
        let setups = AgentIntegrationInstallProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = setup(for: AgentIntegrationDisplayProvider(provider))
        }
        cardModel.refreshAll(setupsByProvider: setups, forcing: true)
    }

    /// Probes only. An install's CLI runs to completion anyway, so it keeps
    /// running and publishes its result for the next time Agents is shown.
    func cancelPendingWork() {
        for (provider, entry) in pluginTasks where entry.isProbe {
            entry.task.cancel()
            pluginTasks[provider] = nil
        }
        cardModel.cancelPendingWork()
    }
}

// MARK: - Shared pieces

@MainActor
enum SetupWizardCopy {
    static var welcomeTitle: String {
        String(localized: "Welcome to awesoMux", comment: "Setup wizard heading on its first step")
    }

    static func themeBackground(store: AppSettingsStore, colorScheme: ColorScheme?) -> String {
        let appearance = store.appearance.value
        if appearance.terminalBackgroundMode == .custom { return appearance.terminalBackgroundColor }
        let effective: TerminalAppearancePreferences.EffectiveTheme =
            switch appearance.theme {
            case .light: .light
            case .dark: .dark
            case .system: colorScheme == .light ? .light : .dark
            }
        return TerminalAppearancePreferences.terminalThemeCatalog
            .provider(for: appearance.terminalThemeID)
            .background(for: effective)
    }
}

/// A settings-style row: a hairline above every row but the first.
private struct WizardRow<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, isFirst ? 0 : 11)
            .padding(.bottom, 11)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(Color.aw.border).frame(height: 0.5)
                }
            }
    }
}

private struct WizardLabel: View {
    let title: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
            if let hint {
                Text(hint)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct WizardSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            WizardLabel(title: title)
        }
        .toggleStyle(AwToggleStyle())
    }
}

private struct WizardKicker: View {
    let text: String
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        Text(text)
            .awFont(AwFont.Mono.kicker)
            .tracking(1.2)
            .textCase(.uppercase)
            // The text-safe accent: the raw Latte accent is under 4.5:1 here.
            .foregroundStyle(Color.aw.accentOnChrome(accentResolver.accent))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tour beat: kicker plus body. `spoken` spells out shortcut glyphs, which
/// VoiceOver reads as ambiguous symbol names.
private struct WizardBeat: View {
    let heading: String
    let visible: String
    var spoken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WizardKicker(text: heading)
            Text(visible)
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(spoken ?? visible)
        }
    }
}

/// Left/Right cards in the `SettingsThemePreview` grid card style.
private struct SidebarPositionCards: View {
    @Binding var selection: AppearanceConfig.SidebarPosition
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            card(.left, title: String(localized: "Left", comment: "Sidebar position option"))
            card(.right, title: String(localized: "Right", comment: "Sidebar position option"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar position")
    }

    private func card(_ position: AppearanceConfig.SidebarPosition, title: String) -> some View {
        let isSelected = selection == position
        let accentColor = Color.aw.accent(accentResolver.accent)
        return Button {
            selection = position
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                preview(position)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: AwRadius.panel - 2))
                Text(title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isSelected ? Color.aw.text : Color.aw.text2)
            }
            .padding(8)
            .frame(width: 90, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AwRadius.panel).fill(Color.aw.surface.elevated))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .stroke(
                        isSelected ? accentColor : Color.aw.border,
                        lineWidth: isSelected ? (contrast == .increased ? 2.5 : 1.5) : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func preview(_ position: AppearanceConfig.SidebarPosition) -> some View {
        let sidebar = Rectangle()
            .fill(Color.aw.surface.sidebar)
            .frame(width: 16)
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.aw.text.opacity(0.55))
                            .frame(width: 10, height: 3)
                    }
                }
                .padding(4)
            }
        let main = Rectangle()
            .fill(Color.aw.surface.window)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.aw.accent(accentResolver.accent))
                        .frame(width: 16, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.aw.text.opacity(0.4))
                        .frame(width: 26, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.aw.text.opacity(0.4))
                        .frame(width: 20, height: 3)
                }
                .padding(6)
            }
        return HStack(spacing: 0) {
            if position == .left {
                sidebar
                main
            } else {
                main
                sidebar
            }
        }
    }
}

// MARK: - D.A.V.E.

private struct DaveMark: View {
    var isSmall = false
    @Environment(\.awAccent) private var accentResolver

    // Art, not copy, so it stays out of the string catalog. The leading
    // `\u{20}` survives whitespace trimming that would shear the head off.
    private static let art = """
        \u{20}   _
        \u{20}__(.)<   H O N K !
        (_____)
        """

    private static let smallArt = """
        \u{20}   _
        \u{20}__(.)<
        (_____)
        """

    var body: some View {
        Text(isSmall ? Self.smallArt : Self.art)
            .awFont(AwFont.Mono.body)
            .foregroundStyle(Color.aw.accent(accentResolver.accent))
            .awGlow(color: Color.aw.accentGlow(accentResolver.accent), radius: 6)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

extension View {
    /// The tour's gap between D.A.V.E. and the beat below, inside a step
    /// stack that is otherwise tighter.
    fileprivate func daveMarkGap() -> some View {
        padding(.bottom, AwSpacing.sectionGap - 16)
    }
}
