import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Offer shown above the Path Bar for an ordinary SSH connection to a host that
/// sets no terminal title. Unlike the managed-workspace sheet, it never takes
/// keyboard focus, so typing continues in the terminal.
struct SSHManagementNotice: View {
    let host: String
    let onManage: () -> Void
    let onDismiss: () -> Void
    // Observed so the primary button re-tints when the accent setting changes.
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        HStack(spacing: 8) {
            // Both parts are already localized.
            Text(verbatim: "\(Self.title(host: host)). \(Self.detail)")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(String(localized: "Manage Connection", comment: "Button on the SSH notice that opens managed-workspace options")) {
                onManage()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.aw.accent(accentResolver.accent))
            // Login input belongs to the terminal: a click must not move
            // keyboard focus here. VoiceOver still reaches both buttons.
            .focusable(false)
            Button(String(localized: "Dismiss", comment: "Button that hides the SSH management notice for this connection")) {
                onDismiss()
            }
            .focusable(false)
        }
        // Same row treatment as the pane's restarted-session notice.
        .awFont(AwFont.Mono.meta)
        .foregroundStyle(Color.aw.text)
        .padding(8)
        .background(Color.aw.surface.chrome)
        .accessibilityElement(children: .contain)
        .onAppear {
            TerminalAccessibilityAnnouncer.announce(
                "\(Self.title(host: host)). \(Self.detail)",
                priority: .low
            )
        }
    }

    static func title(host: String) -> String {
        String(
            localized: "Connected to \(host)",
            comment: "SSH notice title after login finished; the argument is the SSH host"
        )
    }

    static let detail = String(
        localized: "Manage this connection in awesoMux.",
        comment: "SSH notice explanation offering to manage the connection"
    )

    /// Host to show, or nil when the notice should stay hidden. A remote title
    /// takes the managed-workspace sheet path instead, and remembered choices
    /// convert or stay quiet without asking.
    @MainActor
    static func host(
        session: TerminalSession,
        sessionStore: SessionStore,
        workspaces: WorkspaceConfig,
        commandBridgeEnabled: Bool
    ) -> String? {
        guard let pane = session.activePane,
            pane.executionPlan == .local,
            pane.remoteHost == nil,
            pane.hasObservedRemoteSSHLogin,
            let target = sessionStore.pendingManagedSSHWorkspaceOffer(
                sessionID: session.id,
                paneID: pane.id
            )
        else { return nil }
        switch ManagedSSHOfferEffect.resolve(target: target, config: workspaces) {
        case .present:
            return target.host
        case .convert(sessionName: nil) where !commandBridgeEnabled:
            // Automatic conversion needs the command bridge; the sheet asks
            // before turning it on.
            return target.host
        case .convert, .doNothing:
            return nil
        }
    }
}
