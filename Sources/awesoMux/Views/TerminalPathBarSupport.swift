import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Which path bar foldout is open. One optional drives both menus so opening
/// one closes the other and SessionDetailView's click-elsewhere scrim can key
/// on a single `!= nil`.
enum PathBarMenu: Equatable {
    case openTarget
    case branches
}

struct ResolveKey: Equatable {
    /// Re-resolve when the active pane itself changes — a split focus switch or a
    /// recycle can swap to a different pane with the same cwd/title but different
    /// remote state, which the cwd/title fields alone wouldn't catch.
    let activePaneID: TerminalPane.ID?
    let workingDirectory: String
    let paneTitle: String
    let fallbackProject: String
    let isActive: Bool
    let executionPlan: PaneExecutionPlan
    /// Re-resolve when remote state flips even if cwd/title are unchanged.
    let remoteHost: String?
    let remoteConnectionHealth: RemoteConnectionHealth
}

struct MenuDismissKey: Equatable {
    let activePaneID: TerminalPane.ID?
    let remoteHost: String?
    let workingDirectory: String
}

/// Key for the bridge-pane cwd poll task (`bridgePollKey`). Omits
/// `workingDirectory` on purpose — bridge panes never emit OSC 7, so
/// `workingDirectory` is always the stale value; including it would restart
/// the poll on every write-back, creating a spin loop.
struct BridgePollKey: Equatable {
    let activePaneID: TerminalPane.ID?
    let isCommandBridgeEnabled: Bool
    let isActive: Bool
}

struct RemoteIndicatorCopy: Equatable {
    let health: RemoteConnectionHealth
    let icon: String
    let help: String
    let accessibilityLabel: String
    let accessibilityHint: String
}

enum PathBarExecutionAnnouncementState: Equatable {
    case local
    case remote(host: String, health: RemoteConnectionHealth)

    init(pane: TerminalPane?) {
        guard let remote = pane?.executionPlan.remoteTarget else {
            self = .local
            return
        }
        self = .remote(
            host: remote.host,
            health: pane?.remoteConnectionHealth ?? .active
        )
    }
}

enum PathBarExecutionAnnouncement {
    static func message(
        from previous: PathBarExecutionAnnouncementState,
        to current: PathBarExecutionAnnouncementState
    ) -> String? {
        switch (previous, current) {
        case (.local, .local):
            nil
        case (_, let .remote(host, _)) where remoteHost(in: previous) != host:
            String(
                localized: "Pane now runs on \(host).",
                comment: "VoiceOver announcement when the focused pane changes to remote execution"
            )
        case (.remote, .local):
            String(
                localized: "Pane now runs locally.",
                comment: "VoiceOver announcement when the focused pane changes to local execution"
            )
        case (let .remote(host, oldHealth), .remote(_, let newHealth))
        where oldHealth != newHealth:
            switch newHealth {
            case .active:
                String(
                    localized: "Connection to \(host) is active.",
                    comment: "VoiceOver announcement when a remote pane connection recovers"
                )
            case .possiblyStale:
                String(
                    localized: "Connection to \(host) may be stale.",
                    comment: "VoiceOver announcement when a remote pane connection may be stale"
                )
            }
        default:
            nil
        }
    }

    private static func remoteHost(in state: PathBarExecutionAnnouncementState) -> String? {
        guard case let .remote(host, _) = state else { return nil }
        return host
    }
}

/// One completed Path Bar lookup, tagged so the task group can paint the local
/// git status and the network (gh-backed) PR / CI chips independently as each
/// resolves. ("Network" here, not an SSH *remote pane* — those suppress all chips
/// entirely; see `model.remoteHost`.)
enum PathBarChipLookup: Sendable {
    case gitStatus(GitStatusInfo?)
    case pullRequest(PullRequestInfo?)
    case ci(CIStatusInfo?)
}

struct TerminalPathButtonStyle: ButtonStyle {
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let accent = Color.aw.accent(accentResolver.accent)
        configuration.label
            .background(
                accent.opacity(configuration.isPressed ? 0.18 : 0.08),
                in: RoundedRectangle(cornerRadius: AwRadius.pill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.pill)
                    .stroke(accent.opacity(isEnabled ? 0.38 : 0.16), lineWidth: 0.5)
            }
    }
}
