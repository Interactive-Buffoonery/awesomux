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
/// It must stay a bare pass-through: the controller sizes the panel by
/// measuring `SetupWizardPage` for the current step directly.
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

    /// Fixed so a step's height is the only thing that changes between steps.
    static let width: CGFloat = 460

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
                // A new step opens at its top, not at the last step's offset.
                .id(step)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(controller.isHeightCapped ? .automatic : .never)
            }
            footer
                .padding([.horizontal, .bottom], Self.focusInset)
        }
        .padding(AwSpacing.panelPadding - Self.focusInset)
        // Vertical traffic-light clearance: the panel shows standard window
        // buttons and the content starts at the top edge.
        .padding(.top, AwSpacing.titlebar - AwSpacing.panelPadding)
        .frame(width: Self.width, alignment: .leading)
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
            // Step turns and in-step changes (a row appearing, an error line)
            // both move this height; the panel follows it.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in
                guard !isMeasuring else { return }
                controller.fitPanelToCurrentStep()
            }
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
                    presentationToken: presentationToken,
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
            // Large text sizes drop the label first; the buttons never shrink.
            ViewThatFits(in: .horizontal) {
                stepIndicator(showsLabel: true)
                stepIndicator(showsLabel: false)
            }

            Spacer(minLength: 12)

            // Nothing to skip on the last step: Skip and the primary button
            // would both end the wizard.
            if !isLastStep {
                Button(String(localized: "Skip", comment: "Welcome tour button dismissing the tour")) {
                    controller.dismissByUser()
                }
                .awButtonStyle(.link)
            }

            // Shown disabled on the first step so the buttons beside it hold still.
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
    private func stepIndicator(showsLabel: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Color.aw.accentOnChrome(accentResolver.accent) : Color.aw.textFaint)
                        .frame(width: 5, height: 5)
                }
            }

            if showsLabel {
                Text(stepLabel)
                    .awFont(AwFont.Mono.meta)
                    // Primary text: `text2` is under 4.5:1 on the Latte window.
                    .foregroundStyle(Color.aw.text)
                    .fixedSize()
            }
        }
        // The step group already announces "Step N of M".
        .accessibilityHidden(true)
    }
}

// MARK: - Steps

private struct SetupWizardWelcomeStep: View {
    let store: AppSettingsStore

    @Environment(\.colorScheme) private var colorScheme

    private var mode: AppearanceConfig.TerminalBackgroundMode {
        store.appearance.value.terminalBackgroundMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DaveMark().daveMarkGap()
            WizardKicker(text: SetupWizardCopy.welcomeTitle)
            VStack(alignment: .leading, spacing: 8) {
                WizardLabel(
                    title: String(
                        localized: "Terminal background",
                        comment: "Setup wizard label for the terminal background choice")
                )
                // The chip group carries the same name.
                .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    backgroundChips(isVertical: false)
                    backgroundChips(isVertical: true)
                }
                if mode == .custom { WizardCustomBackgroundCaption() }
                WizardTerminalPreview(
                    backgroundHex: SetupWizardCopy.themeBackground(store: store, colorScheme: colorScheme),
                    usesGhosttyConfig: mode == .ghostty)
            }
        }
    }

    /// A custom background matches neither option, so neither shows selected
    /// until the user picks one.
    private func backgroundChips(isVertical: Bool) -> some View {
        WizardChips(
            accessibilityLabel: String(
                localized: "Terminal background",
                comment: "Setup wizard label for the terminal background choice"),
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
            selection: store.appearance.binding(\.terminalBackgroundMode),
            isVertical: isVertical)
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
                // A custom background matches no theme, so no chip shows it.
                guard appearance.terminalBackgroundMode != .custom else { return "" }
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
                WizardChoiceRow(
                    title: String(localized: "Theme", comment: "Setup wizard label for the app theme"), isFirst: true,
                    options: AppearanceConfig.Theme.cardDisplayOrder.map { .init(value: $0, label: $0.displayName) },
                    selection: store.appearance.binding(\.theme))
                WizardChoiceRow(
                    title: String(localized: "Accent", comment: "Setup wizard label for the accent color"),
                    options: AwAccent.allCases.map {
                        .init(value: $0, label: $0.displayName, swatch: Color.aw.accent($0))
                    },
                    selection: accent)
                if showsTerminalTheme {
                    WizardChoiceRow(
                        title: String(localized: "Terminal theme", comment: "Label for the terminal color theme picker"),
                        options: [
                            .init(
                                value: TerminalThemeCatalog.catppuccinID,
                                label: String(
                                    localized: "Catppuccin", comment: "Name of the Catppuccin terminal color theme")),
                            .init(
                                value: TerminalThemeCatalog.selenizedID,
                                label: String(
                                    localized: "Selenized", comment: "Name of the Selenized terminal color theme")),
                        ],
                        selection: terminalTheme)
                }
                WizardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        if appearance.terminalBackgroundMode == .custom { WizardCustomBackgroundCaption() }
                        WizardTerminalPreview(
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
                WizardChoiceRow(
                    title: String(localized: "Position", comment: "Setup wizard label for the sidebar position"),
                    isFirst: true,
                    options: [
                        .init(value: .left, label: String(localized: "Left", comment: "Sidebar position option")),
                        .init(value: .right, label: String(localized: "Right", comment: "Sidebar position option")),
                    ],
                    selection: store.appearance.binding(\.sidebarPosition))
                WizardChoiceRow(
                    title: String(localized: "Open on", comment: "Setup wizard label for the sidebar shown at launch"),
                    options: [
                        .init(
                            value: AppearanceConfig.SidebarMode.workspaces,
                            label: String(localized: "Workspaces", comment: "Sidebar mode option")),
                        .init(
                            value: AppearanceConfig.SidebarMode.agents,
                            label: String(localized: "Agents", comment: "Sidebar mode option")),
                    ],
                    selection: store.appearance.binding(\.defaultSidebar))
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
    let presentationToken: Int
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

    private var notificationStatusColor: Color {
        switch notifications.status {
        case .unknown, .notDetermined: Color.aw.textFaint
        case .authorized: Color.aw.green
        case .denied: Color.aw.red
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
                    WizardRow(isFirst: display == AgentIntegrationDisplayProvider.allCases.first) {
                        SetupWizardAgentRow(display: display, agents: agents)
                    }
                }
                WizardRow {
                    HStack(spacing: 10) {
                        WizardLabel(
                            title: String(
                                localized: "Notifications", comment: "Setup wizard label for notification permission")
                        )
                        // The status element carries the same name.
                        .accessibilityHidden(true)
                        WizardStatus(
                            label: notificationStatus, color: notificationStatusColor,
                            accessibilityLabel: String(
                                localized: "Notifications",
                                comment: "Setup wizard label for notification permission"))
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
                    let isAvailable = notifications.status == .authorized
                    let hint = String(
                        localized: "Allow notifications first",
                        comment: "Setup wizard hint under the needs-input switch while notifications are not allowed")
                    VStack(alignment: .leading, spacing: 4) {
                        WizardSwitch(
                            title: String(
                                localized: "Notify when an agent needs input",
                                comment: "Setup wizard switch for needs-input notifications"),
                            isOn: store.notifications.binding(\.notifyOnNeedsAttention)
                        )
                        .disabled(!isAvailable)
                        .accessibilityHint(isAvailable ? "" : hint)
                        if !isAvailable {
                            WizardCaption(text: hint)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        // Also per presentation: the page outlives a dismiss, and dismissing
        // cancelled the probes a reopen on this step must restart.
        .onChange(of: presentationToken, initial: true) { _, _ in
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

            // Tighter below: the goose's first row is mostly empty space, so
            // this reads as the same gap as above the dots.
            VStack(alignment: .leading, spacing: 8) {
                WizardDotsDivider()

                HStack(spacing: 10) {
                    DaveMark(isSmall: true)
                    Text(
                        String(
                            localized: "Go build something awesome…ux. (I'm an AI Goose, I did my best, sorry.) — D.A.V.E.",
                            comment: "Setup wizard sign-off; D.A.V.E. is the mascot.")
                    )
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.railText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
            row(title: state.title, isEnabled: isEnabled, isBusy: state.isBusy) {
                if isEnabled {
                    WizardStatus(
                        label: state.statusLabel,
                        color: AgentPluginStatusBadge.color(for: state.status),
                        accessibilityLabel: statusAccessibilityLabel(state.title),
                        accessibilityHint: state.statusDetail)
                    if state.allowsEnable {
                        installButton(title: state.title) { pendingConfirmation = agents.confirmation(provider) }
                    }
                }
            } detail: {
                // Only problems earn a second line; healthy rows stay one line.
                if isEnabled {
                    if let failure = agents.pluginInstallFailures[provider] {
                        detailText(failure, isFailure: true)
                    } else {
                        detailText(
                            state.failureSummary ?? state.guidance ?? (state.needsAttention ? state.statusDetail : nil))
                    }
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
            row(title: state.title, isEnabled: isEnabled, isBusy: false) {
                if isEnabled {
                    WizardStatus(
                        label: state.isAuthoritative
                            ? state.status.label
                            : String(
                                localized: "Checking…",
                                comment: "Agent integration status badge while a check is in flight"),
                        color: state.status.badgeColor,
                        accessibilityLabel: statusAccessibilityLabel(state.title),
                        accessibilityHint: state.status.detail)
                    if state.canInstall {
                        installButton(title: state.title) { agents.install(provider) }
                    }
                }
            } detail: {
                if isEnabled {
                    if let error {
                        detailText(error, isFailure: true)
                    } else {
                        detailText(Self.needsAttention(state.status) ? state.status.detail : nil)
                    }
                }
            }
        }
    }

    private static func needsAttention(_ status: AgentIntegrationSettingsStatus) -> Bool {
        switch status {
        case .updateAvailable, .installStateRepairRequired, .timedOut, .blocked: true
        default: false
        }
    }

    private func statusAccessibilityLabel(_ title: String) -> String {
        String(
            localized: "\(title) status",
            comment: "Accessibility label for an agent plugin status badge; argument is the provider name.")
    }

    private func row(
        title: String,
        isEnabled: Bool,
        isBusy: Bool,
        @ViewBuilder status: () -> some View,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The row's spare width toggles too. Hidden from VoiceOver:
                // the switch and status already carry the name.
                WizardLabel(title: title)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isBusy else { return }
                        agents.setEnabled(!isEnabled, for: display)
                    }
                    .accessibilityHidden(true)
                status()
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
                .accessibilityLabel(
                    String(
                        localized: "\(title) integration",
                        comment: "Accessibility label for an agent integration switch; argument is the provider name.")
                )
                .accessibilityValue(
                    isEnabled
                        ? String(localized: "Enabled", comment: "Accessibility value of an agent integration switch")
                        : String(localized: "Disabled", comment: "Accessibility value of an agent integration switch"))
            }
            detail()
        }
    }

    private func installButton(title: String, action: @escaping () -> Void) -> some View {
        Button(String(localized: "Install", comment: "Setup wizard button installing an agent integration"), action: action)
            .awButtonStyle(.primary)
            .accessibilityLabel(
                String(
                    localized: "Install \(title) integration",
                    comment: "Accessibility label for a setup wizard install button; argument is the provider name."))
    }

    /// Install failures read in the error color (4.8:1 on the Latte window);
    /// other notes use the corrected secondary text.
    @ViewBuilder
    private func detailText(_ text: String?, isFailure: Bool = false) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(isFailure ? Color.aw.red : Color.aw.railText)
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
    /// Kept apart from the probe status: the entry probe clears the view
    /// model's failure, which would hide an install that failed after dismiss.
    private(set) var pluginInstallFailures: [AgentPluginProvider: String] = [:]
    @ObservationIgnored private var isShowingAgents = false

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
            pluginInstallFailures[provider] = nil
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
        pluginInstallFailures[provider] = nil
        runPluginTask(provider, isProbe: false) { [weak self] model, target, setup in
            let outcome = await model.perform(action: .enableOrInstall, target: target, setup: setup)
            self?.pluginInstallFailures[provider] = outcome.flatMap(Self.installFailure)
        }
    }

    /// Taken from the outcome, not the card: a failure without diagnostics
    /// (install-state lock contention) has no failure summary, and the next
    /// probe replaces its status.
    private static func installFailure(_ outcome: AgentPluginActionOutcome) -> String? {
        switch outcome.status {
        case .needsRepair, .unsupported: outcome.status.detail
        default: AgentPluginSettingsViewModel.failureSummary(outcome)
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
            guard let self else { return }
            if pluginTasks[provider]?.id == id {
                pluginTasks[provider] = nil
            }
            // A probe started while this cancelled one was draining saw the
            // target as still probing and quit, so it never published.
            if isProbe, Task.isCancelled, isShowingAgents {
                probe(provider)
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
        isShowingAgents = true
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
        isShowingAgents = false
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
            .padding(.top, isFirst ? 0 : 9)
            .padding(.bottom, 9)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(Color.aw.border).frame(height: 0.5)
                }
            }
    }
}

private struct WizardLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .awFont(AwFont.Mono.meta)
            .fontWeight(.medium)
            .foregroundStyle(Color.aw.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status dot plus mono label, the wizard's flat take on the Settings badge.
private struct WizardStatus: View {
    let label: String
    let color: Color
    let accessibilityLabel: String
    var accessibilityHint = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.railText)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(label)
        .accessibilityHint(accessibilityHint)
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

private struct WizardChoice<Value: Hashable> {
    let value: Value
    let label: String
    var swatch: Color?
}

/// Mono pill chips for a single choice. Callers stack them in a column when
/// a row is too narrow, so large text sizes never clip a label.
private struct WizardChips<Value: Hashable>: View {
    let accessibilityLabel: String
    let options: [WizardChoice<Value>]
    @Binding var selection: Value
    var isVertical = false

    var body: some View {
        Group {
            if isVertical {
                VStack(alignment: .leading, spacing: 6) { chips }
            } else {
                HStack(spacing: 6) { chips }.fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var chips: some View {
        ForEach(options, id: \.value) { option in
            let isSelected = option.value == selection
            Button {
                selection = option.value
            } label: {
                HStack(spacing: 6) {
                    if let swatch = option.swatch {
                        Circle()
                            .fill(swatch)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Text(option.label)
                }
            }
            .buttonStyle(WizardChipStyle(isSelected: isSelected))
            .focusEffectDisabled()
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}

/// A labelled chip row: chips beside the label, then under it, then in a
/// column, whichever fits first.
private struct WizardChoiceRow<Value: Hashable>: View {
    let title: String
    var isFirst = false
    let options: [WizardChoice<Value>]
    @Binding var selection: Value

    var body: some View {
        WizardRow(isFirst: isFirst) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    label
                    chips(isVertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    label
                    chips(isVertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    label
                    chips(isVertical: true)
                }
            }
        }
    }

    /// The chip group carries the same name for VoiceOver.
    private var label: some View {
        WizardLabel(title: title).accessibilityHidden(true)
    }

    private func chips(isVertical: Bool) -> some View {
        WizardChips(accessibilityLabel: title, options: options, selection: $selection, isVertical: isVertical)
    }
}

private struct WizardChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        WizardChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct WizardChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var isHovered = false

    var body: some View {
        let accent = accentResolver.accent
        let shape = RoundedRectangle(cornerRadius: AwRadius.pill)
        let isActive = isEnabled && (isHovered || configuration.isPressed)
        HStack(spacing: 6) {
            configuration.label
            // Same cue as `SettingsSegmented`: selection without relying on fill.
            if isSelected, differentiateWithoutColor {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .awFont(AwFont.Mono.meta)
        .fontWeight(isSelected ? .medium : .regular)
        .foregroundStyle(isSelected || isActive ? Color.aw.text : Color.aw.railText)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background {
            if isSelected {
                shape.fill(Color.aw.accentSoft(accent))
            } else if isActive {
                shape.fill(Color.aw.surface.hover)
            }
        }
        .overlay {
            // Softer than the primary button, so the chip never reads as the CTA.
            if isSelected {
                shape.strokeBorder(
                    Color.aw.accent(accent).opacity(contrast == .increased ? 1 : 0.4),
                    lineWidth: contrast == .increased ? 2 : 1)
            } else {
                shape.strokeBorder(Color.aw.border2, lineWidth: 0.5)
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.4)
        .awFocusRing(isFocused, cornerRadius: AwRadius.pill, inset: -2)
        .onHover { isHovered = $0 }
    }
}

/// A mono terminal sample on the chosen background. In Ghostty-config mode
/// the user's config owns the color, so a swatch would guess wrong.
private struct WizardTerminalPreview: View {
    let backgroundHex: String
    let usesGhosttyConfig: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AwRadius.panel)
        if usesGhosttyConfig {
            // Filled, not outlined: an empty outline reads as a text field.
            Text("Your Ghostty config controls the terminal background.")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.railText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.aw.surface.chrome, in: shape)
        } else {
            let background = NSColor.awesoMuxSettingsHex(backgroundHex) ?? .black
            Text(verbatim: "you@awesomux ~/project\n❯ claude\n✓ background preview text")
                .awFont(AwFont.Mono.meta)
                .lineSpacing(2)
                .foregroundStyle(TerminalBackgroundPreviewForeground.color(for: background))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: background), in: shape)
                .overlay { shape.strokeBorder(Color.aw.border2, lineWidth: 0.5) }
                // The sample prompt is purely visual; speaking it is noise.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview of terminal background")
        }
    }
}

/// Secondary mono line. `railText` because stock `text2` is 4.37:1 on the
/// Latte window, under 4.5:1.
private struct WizardCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .awFont(AwFont.Mono.meta)
            .foregroundStyle(Color.aw.railText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WizardCustomBackgroundCaption: View {
    var body: some View {
        WizardCaption(
            text: String(
                localized: "Using your custom background.",
                comment: "Setup wizard note shown while a custom terminal background color is set"))
    }
}

/// Three spaced dots, like the WordPress separator block's dots style.
/// Decorative, so it is softer than text and hidden from VoiceOver.
private struct WizardDotsDivider: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 4, height: 4)
            }
        }
        .foregroundStyle(Color.aw.railText.opacity(0.6))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
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
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.railText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(spoken ?? visible)
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
