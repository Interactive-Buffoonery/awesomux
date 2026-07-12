import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct AwesoMuxSettingsView: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var selection: SettingsSectionID = .general
    @State private var escapeMonitor = SettingsEscapeMonitor()

    var body: some View {
        SettingsShell(
            selection: $selection,
            sidebar: { sidebar },
            detail: { detailWithBanner }
        )
        // Escape closes the window, matching the macOS convention for a
        // settings/preferences window. `.onExitCommand` / `@Environment(\.dismiss)`
        // don't fire here because the `Settings` scene has nothing in its
        // responder chain when no control is focused, so Escape falls through to
        // the system beep. A scoped local key-down monitor catches it instead,
        // acting only on the window captured by the accessor below.
        .background(WindowAccessor { escapeMonitor.window = $0 })
        .onAppear { escapeMonitor.start() }
        .onDisappear { escapeMonitor.stop() }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSectionID.allCases) { section in
                SettingsSidebarItem(
                    section: section,
                    title: section.title,
                    systemImage: section.systemImage,
                    selection: $selection
                )
            }
        }
    }

    @ViewBuilder
    private var detailWithBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shown on every pane: while the on-disk config is invalid, edits
            // made anywhere in Settings are held in memory and never persisted,
            // so the user must resolve the file before changes can stick.
            if appSettingsStore.isDiskConfigInvalid, selection != .advanced {
                invalidConfigBanner
            }
            detail
        }
    }

    private var invalidConfigBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.aw.peach)
                .accessibilityHidden(true)
            Text("The config file on disk is invalid. Changes made here won't be saved until it's fixed.")
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
            Spacer()
            Button("Review in Advanced") { selection = .advanced }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AwRadius.button)
                .fill(Color.aw.surface.elevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .padding([.horizontal, .top], 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsPane()
        case .appearance:
            AppearanceSettingsPane()
        case .terminal:
            TerminalSettingsPane()
        case .agents:
            AgentsSettingsPane()
        case .notifications:
            NotificationSettingsPane()
        case .workspaces:
            WorkspaceSettingsPane()
        case .keys:
            KeysSettingsPane()
        case .advanced:
            AdvancedSettingsPane()
        case .diagnostics:
            DiagnosticsSettingsPane()
        }
    }
}

enum SettingsSectionID: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case terminal
    case agents
    case notifications
    case workspaces
    case keys
    case advanced
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .notifications: "Notifications"
        case .workspaces: "Workspaces"
        case .keys: "Keys"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .agents: "person.2"
        case .notifications: "bell"
        case .workspaces: "sidebar.left"
        case .keys: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}
