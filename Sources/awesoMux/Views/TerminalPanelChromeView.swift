import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import Foundation
import SwiftUI

/// Unified chrome for both terminal-panel modes. The header and footer adapt to
/// `mode`: companion shows minimize + close and a promote/⌘W footer; floating
/// shows a folder + subtitle and an esc/⌘W/⌘⏎ footer. Both host `TerminalPaneView`
/// and fill the resizable window. Supersedes `PopUpTerminalView` + `FloatingPanelView`.
@MainActor
struct TerminalPanelChromeView: View {
    let mode: TerminalPanelMode
    let sessionStore: SessionStore
    let ghosttyRuntime: GhosttyRuntime
    let appSettingsStore: AppSettingsStore
    let focusState: FloatingPanelFocusState
    let parentWorkspaceTitle: String?    // floating mode only
    let onMinimize: () -> Void           // companion
    let onClose: () -> Void              // companion
    let onDismiss: () -> Void            // floating
    let onMakeWorkspace: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // Promotion compression is floating-only; companion never leaves
        // `.idle`, so this is a no-op there.
        .scaleEffect(focusState.promotionPhase == .compressing ? 0.96 : 1)
        .opacity(focusState.promotionPhase == .compressing ? 0.6 : 1)
        .frame(minWidth: mode.minimumSize.width, minHeight: mode.minimumSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // fill the resizable window in both modes
        .background(panelBackground)
        .clipShape(panelShape)
        .overlay {
            panelShape
                .stroke(strokeColor, lineWidth: focusState.isKeyWindow ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .environment(appSettingsStore)
        .appearanceBridge(appSettingsStore)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if mode.hasCornerTab {
            companionHeader(session: sessionStore.selectedSession)
        } else {
            floatingHeader
        }
    }

    private func companionHeader(session: TerminalSession?) -> some View {
        let directoryText = session?.workingDirectory ?? String(
            localized: "Terminal unavailable",
            comment: "Fallback header shown when the Terminal Companion store has no selected session."
        )

        return HStack(spacing: 10) {
            Text(directoryText)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            PopUpTerminalMinimizeButton(action: onMinimize)
            FloatingPanelCloseButton(
                accessibilityLabel: String(
                    localized: "Close Terminal Companion",
                    comment: "Accessibility label for the Terminal Companion close button."
                ),
                action: onClose
            )
        }
        .foregroundStyle(Color.aw.text)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.aw.surface.chrome2.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.aw.border2).frame(height: 0.5)
        }
    }

    private var floatingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName)
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)

                Text(headerSubtitle)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Color.aw.surface.chrome2.opacity(0.50))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if mode.hasCornerTab {
            if let session = sessionStore.selectedSession {
                TerminalPaneView(
                    session: session,
                    sessionStore: sessionStore,
                    ghosttyRuntime: ghosttyRuntime
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.aw.surface.terminal)
                companionFooter(session: session)
            } else {
                unavailablePlaceholder
            }
        } else {
            TerminalPaneView(
                session: floatingSession,
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.aw.surface.terminal)
            floatingFooter
        }
    }

    private func companionFooter(session: TerminalSession) -> some View {
        let status = session.effectiveChromeState.awState

        return HStack(spacing: 10) {
            StatusDot(status)
            Text(status.label)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
            Spacer(minLength: 8)
            PopUpTerminalPromoteButton(action: onMakeWorkspace)
            minimizeHint
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.aw.surface.chrome2.opacity(0.82))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.border2).frame(height: 0.5)
        }
    }

    private var floatingFooter: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 12)

            FloatingHintChip(
                kbd: "esc",
                label: focusState.discardConfirmationPending ? "again to discard" : "dismiss",
                isPrimary: true
            )
            FloatingHintChip(kbd: "⌘W", label: "hide", isPrimary: false)
            FloatingHintChip(kbd: "⌘⏎", label: "promote", isPrimary: false)
        }
        .padding(.horizontal, AwSpacing.panelPadding)
        .frame(height: 48)
        .background(Color.aw.surface.chrome2.opacity(0.70))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.aw.border2)
                .frame(height: 0.5)
        }
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
            Text("Terminal session unavailable", comment: "Placeholder title in the Terminal Companion when no session exists.")
                .awFont(AwFont.UI.body)
            Text("Close and reopen Terminal Companion to start a new session.", comment: "Placeholder guidance in the Terminal Companion when no session exists.")
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
        }
        .foregroundStyle(Color.aw.text2)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.aw.surface.terminal)
        .accessibilityElement(children: .combine)
    }

    private var minimizeHint: some View {
        HStack(spacing: 5) {
            KBD("⌘W")
            Text("minimize", comment: "Footer pill label for the Terminal Companion minimize shortcut hint.")
                .awFont(AwFont.Mono.pill)
                .foregroundStyle(Color.aw.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "Command W minimizes the Terminal Companion",
            comment: "Accessibility label for the Terminal Companion minimize shortcut hint."
        ))
    }

    // MARK: - Shared chrome

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopUpTerminalLayout.cornerRadius)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color.aw.surface.chrome
        } else {
            PopUpTerminalPanelGradient()
        }
    }

    private var strokeColor: Color {
        focusState.isKeyWindow ? Color.aw.border2 : Color.aw.border
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        if mode.hasCornerTab {
            return companionAccessibilityLabel(for: sessionStore.selectedSession)
        }
        return floatingAccessibilityLabel
    }

    private var accessibilityHint: String {
        if mode.hasCornerTab {
            return String(
                localized: "Press Command-W or use Minimize to minimize. Use Close to end the terminal.",
                comment: "Accessibility hint on the expanded Terminal Companion window."
            )
        }
        return floatingAccessibilityHint
    }

    private func companionAccessibilityLabel(for session: TerminalSession?) -> String {
        guard let session else {
            return String(
                localized: "Terminal Companion unavailable",
                comment: "Accessibility label when the Terminal Companion store has no selected session."
            )
        }
        return String(
            localized: "Terminal Companion, \(session.workingDirectory), \(session.effectiveChromeState.awState.label)",
            comment: "Accessibility label containing the Terminal Companion directory and status."
        )
    }

    private var floatingAccessibilityLabel: String {
        if let parentWorkspaceTitle, !parentWorkspaceTitle.isEmpty {
            return "Floating terminal panel for \(parentWorkspaceTitle)"
        }
        return "Floating terminal panel"
    }

    private var floatingAccessibilityHint: String {
        if focusState.discardConfirmationPending {
            return "Running work is active. Press Escape again to discard, Command-W to hide, or Command-Return to promote into the workspace."
        }
        return "Press Escape to dismiss, Command-W to hide, or Command-Return to promote into the workspace."
    }

    // MARK: - Floating content helpers

    private var headerSubtitle: String {
        if let parentWorkspaceTitle, !parentWorkspaceTitle.isEmpty {
            return parentWorkspaceTitle
        }
        return "ephemeral shell"
    }

    private var floatingSession: TerminalSession {
        guard let session = sessionStore.selectedSession else {
            return TerminalSession(
                title: "floating panel",
                // Canonical home, matching ingest-canonicalized working
                // directories — a raw home here would dodge the display layer's
                // home-prefix strip under a symlinked home (INT-498).
                workingDirectory: WorkingDirectoryValidator.canonicalHomeDirectory,
                agentKind: .shell,
                agentState: AgentKind.shell.initialSessionState
            )
        }

        return session
    }

    private var folderName: String {
        let directory = floatingSession.workingDirectory
        guard directory != "~" else {
            return "~"
        }

        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let lastComponent = trimmed.split(separator: "/").last else {
            return directory
        }

        return String(lastComponent)
    }
}

/// Children of the panel view so the accent read happens below
/// `.appearanceBridge` — an `@Environment(\.awAccent)` on the top-level view
/// resolves at the hosting root, which would pin the default resolver for the
/// window's lifetime.
private struct PopUpTerminalPanelGradient: View {
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        ZStack {
            Color.aw.surface.chrome.opacity(0.96)
            LinearGradient(
                colors: [
                    Color.aw.accent(accentResolver.accent).opacity(0.10),
                    .clear,
                    Color.aw.teal.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Mirrors `FloatingPanelCloseButton`'s explicit focus ring so every control
/// on this translucent chrome is visibly focusable (WCAG 2.4.7); accent
/// instead of red because minimize isn't destructive.
private struct PopUpTerminalMinimizeButton: View {
    let action: () -> Void

    @Environment(\.awAccent) private var accentResolver
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay {
            Circle().stroke(
                isFocused
                    ? Color.aw.accent(accentResolver.accent)
                        .opacity(FloatingPanelChromeMetrics.focusRingOpacity)
                    : Color.clear,
                lineWidth: FloatingPanelChromeMetrics.focusRingLineWidth
            )
        }
        .focused($isFocused)
        .help(String(
            localized: "Minimize Terminal Companion",
            comment: "Tooltip on the Terminal Companion minimize button."
        ))
        .accessibilityLabel(String(
            localized: "Minimize Terminal Companion",
            comment: "Accessibility label for the Terminal Companion minimize button."
        ))
    }
}

private struct PopUpTerminalPromoteButton: View {
    let action: () -> Void

    @Environment(\.awAccent) private var accentResolver
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                KBD("⌘⏎")
                Text("promote", comment: "Footer pill label for promoting the Terminal Companion to a workspace.")
            }
            .awFont(AwFont.Mono.pill)
            .foregroundStyle(Color.aw.text3)
        }
        .buttonStyle(.plain)
        .overlay {
            Capsule()
                .inset(by: -3)
                .stroke(
                    isFocused
                        ? Color.aw.accent(accentResolver.accent)
                            .opacity(FloatingPanelChromeMetrics.focusRingOpacity)
                        : Color.clear,
                    lineWidth: FloatingPanelChromeMetrics.focusRingLineWidth
                )
        }
        .focused($isFocused)
        .accessibilityLabel(String(
            localized: "Promote to workspace, Command Return",
            comment: "Accessibility label for the Terminal Companion promote button; action first, shortcut second."
        ))
    }
}

private struct FloatingHintChip: View {
    let kbd: String
    let label: String
    let isPrimary: Bool

    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        HStack(spacing: 6) {
            KBD(kbd)
                .opacity(isPrimary ? 1 : 0.82)

            Text(label)
                .awFont(AwFont.Mono.pill)
                .foregroundStyle(isPrimary ? Color.aw.accent(accentResolver.accent) : Color.aw.text3)
        }
        .accessibilityElement(children: .combine)
    }
}
