import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

@MainActor
struct PopUpTerminalCornerTabView: View {
    let sessionStore: SessionStore
    let appSettingsStore: AppSettingsStore
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .frame(width: PopUpTerminalLayout.cornerTabSize.width, height: PopUpTerminalLayout.cornerTabSize.height)
            .background(Color.aw.surface.chrome.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .environment(appSettingsStore)
        .appearanceBridge(appSettingsStore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(String(
            localized: "Opens the Terminal Companion",
            comment: "Accessibility hint on the minimized Terminal Companion corner tab."
        ))
    }

    private var fallbackCommandLabel: String {
        String(localized: "Shell", comment: "Corner tab command label when the companion runs a plain shell.")
    }

    private var state: CornerTabState {
        CornerTabState.resolve(
            session: sessionStore.selectedSession,
            fallbackCommand: fallbackCommandLabel,
            fallbackDirectory: WorkingDirectoryValidator.canonicalHomeDirectory
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .active(command, directory, status):
            CornerTabAccentIcon()
            VStack(alignment: .leading, spacing: 1) {
                Text(command)
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
                Text(directory)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            StatusDot(status)
            Text(status.label)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
        case let .ended(directory):
            CornerTabEndedIcon()
            VStack(alignment: .leading, spacing: 1) {
                Text("Session ended", comment: "Corner tab label when the companion shell has exited while minimized.")
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(1)
                Text(directory)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Image(systemName: "poweroff")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.aw.textFaint)
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case let .active(command, directory, status):
            String(
                localized: "Restore Terminal Companion, \(command), \(status.label), \(directory)",
                comment: "Accessibility label for the minimized Terminal Companion corner tab: command, status, directory."
            )
        case let .ended(directory):
            String(
                localized: "Restore Terminal Companion, session ended, \(directory)",
                comment: "Accessibility label for the minimized Terminal Companion corner tab when the shell has exited."
            )
        }
    }
}

/// Child view so the accent read happens below `.appearanceBridge` — an
/// `@Environment(\.awAccent)` on the top-level view resolves at the hosting
/// root, which would pin the default resolver for the window's lifetime.
private struct CornerTabAccentIcon: View {
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        Image(systemName: "terminal")
            .foregroundStyle(Color.aw.accent(accentResolver.accent))
    }
}

/// Dimmed terminal glyph for the ended state — same icon as the active tab so
/// restoring doesn't feel like a different affordance, just muted to
/// `text3`. Needs no accent read, unlike `CornerTabAccentIcon`, since ended
/// tabs never carry the accent tint.
private struct CornerTabEndedIcon: View {
    var body: some View {
        Image(systemName: "terminal")
            .foregroundStyle(Color.aw.text3)
    }
}
