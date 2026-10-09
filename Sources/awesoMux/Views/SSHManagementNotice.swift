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
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 17))
                .foregroundStyle(Color.aw.text2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(host: host))
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                Text(Self.detail)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            PermissionActionButton(
                title: String(
                    localized: "Manage Connection",
                    comment: "Button on the SSH notice that opens managed-workspace options"
                ),
                accessibilityLabel: String(
                    localized: "Manage connection to \(host)",
                    comment: "Accessibility label for the SSH notice's manage button; the argument is the SSH host"
                ),
                tint: Color.aw.accent(accentResolver.accent),
                isProminent: true,
                action: onManage
            )
            .frame(minWidth: 24, minHeight: 24)
            .layoutPriority(1)

            PermissionActionButton(
                title: String(
                    localized: "Dismiss",
                    comment: "Button that hides the SSH management notice for this connection"
                ),
                accessibilityLabel: String(
                    localized: "Dismiss notice for \(host)",
                    comment: "Accessibility label for the SSH notice's dismiss button; the argument is the SSH host"
                ),
                tint: Color.aw.text2,
                action: onDismiss
            )
            .frame(minWidth: 24, minHeight: 24)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background {
            Color.aw.surface.chrome
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.aw.border2)
                        .frame(height: 0.5)
                }
        }
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
