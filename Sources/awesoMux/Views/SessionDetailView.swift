import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SessionDetailView: View {
    let session: TerminalSession?
    let sessionStore: SessionStore
    let ghosttyRuntime: GhosttyRuntime
    let onRenameWorkspace: (TerminalSession) -> Void
    /// Announcing reopen handler shared with the menu / keyboard command so the
    /// on-screen button posts the same VoiceOver feedback on both success and
    /// nil (INT-166 review: the button used to call the store directly and
    /// silently no-op when reopen returned nil).
    let onReopenClosedWorkspace: () -> Void
    let onOpenSelectedWorkspaceInIDE: () -> Void
    let onOpenSelectedWorkspaceInIDEWithApp: (URL, InstalledIDE) -> Void
    let onFooterHeightChange: (CGFloat) -> Void
    let hasRecoveryWarning: Bool
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var presentedPathBarMenu: PathBarMenu?

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 0) {
                        if session.needsAcknowledgement {
                            // No transition/animation here — animating this in/out
                            // resizes the terminal grid continuously mid-transition
                            // (worse than one instant jump; see libghostty resize
                            // gotchas elsewhere in this codebase). Tried and reverted.
                            NeedsInputBar(
                                session: session,
                                onAcknowledge: {
                                    // Workspace-scoped, matching the ⌘⇧K action the
                                    // button advertises: the banner shows when ANY
                                    // pane needs input, so an active-pane-only ack
                                    // silently no-ops whenever the attention sits on
                                    // a sibling pane in a split.
                                    sessionStore.acknowledgeAllPanes(in: session.id)
                                }
                            )
                        }

                        // INT-698 D4: the remote-agent permission banner for the
                        // active pane, above the terminal. Self-gates on
                        // `activePrompt != nil`; only mounted when a live bridge
                        // generation for the active pane has a coordinator.
                        if let terminalSessionID = session.layout.pane(id: session.activePaneID)?.terminalSessionID,
                           let coordinator = ghosttyRuntime.bridgeCoordinatorStore.coordinator(for: terminalSessionID) {
                            BridgePermissionPromptView(coordinator: coordinator)
                        }

                        TerminalPaneView(
                            session: session,
                            sessionStore: sessionStore,
                            ghosttyRuntime: ghosttyRuntime
                        )
                    }

                    if presentedPathBarMenu != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                presentedPathBarMenu = nil
                            }
                    }
                }

                TerminalPathBarView(
                    session: session,
                    sendTextToActivePane: { text in
                        ghosttyRuntime.sendText(text, toPane: session.activePaneID)
                    },
                    sessionStore: sessionStore,
                    isCommandBridgeEnabled: appSettingsStore.terminal.value.commandBridgeEnabled,
                    openInIDE: onOpenSelectedWorkspaceInIDE,
                    openInIDEWithApp: onOpenSelectedWorkspaceInIDEWithApp,
                    isOpenInIDEEnabled: appSettingsStore.workspaces.value.openInIDEEnabled,
                    idePriority: appSettingsStore.workspaces.value.defaultIDEPriority,
                    presentedMenu: $presentedPathBarMenu
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onFooterHeightChange(height)
                }
            }
            .background(Color.aw.surface.terminal)
        } else {
            EmptyWorkspaceView(
                mode: emptyStateMode,
                onNewWorkspace: {
                    sessionStore.addSession(
                        groupName: appSettingsStore.workspaces.value.defaultGroup
                    )
                },
                onOpenRecent: onReopenClosedWorkspace,
                canReopenWorkspace: sessionStore.canReopenClosedWorkspace
            )
            .foregroundStyle(Color.aw.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.aw.surface.terminal)
            .onAppear {
                onFooterHeightChange(0)
            }
        }
    }

    private var emptyStateMode: EmptyWorkspaceMode {
        if hasRecoveryWarning {
            return .recovered
        }
        // A truly empty tree is a genuine cold launch / all-closed state; a
        // non-empty tree with no selection is a returning user between
        // workspaces, so don't greet them as new (INT-166 review).
        return sessionStore.groups.isEmpty ? .firstLaunch : .noSelection
    }
}

private enum EmptyWorkspaceMode {
    case firstLaunch
    case noSelection
    case recovered
}

private struct EmptyWorkspaceView: View {
    let mode: EmptyWorkspaceMode
    let onNewWorkspace: () -> Void
    let onOpenRecent: () -> Void
    let canReopenWorkspace: Bool

    @Environment(\.awAccent) private var accentResolver
    @AccessibilityFocusState private var primaryActionFocused: Bool
    @State private var didFocusInitial = false

    private var heading: LocalizedStringResource {
        switch mode {
        case .firstLaunch:
            return LocalizedStringResource(
                "welcome to awesoMux",
                comment: "Heading shown when the app has no workspaces on first launch."
            )
        case .noSelection:
            return LocalizedStringResource(
                "no workspace selected",
                comment: "Heading shown when workspaces exist but none is selected."
            )
        case .recovered:
            return LocalizedStringResource(
                "session set aside safely",
                comment: "Heading shown after an invalid saved session was quarantined."
            )
        }
    }

    private var bodyText: LocalizedStringResource {
        switch mode {
        case .recovered:
            return LocalizedStringResource(
                "We found a problem with your saved session and set it aside safely. Create a workspace with Command-N to start fresh.",
                comment: "Recovery explanation shown after an invalid saved session was quarantined."
            )
        case .firstLaunch, .noSelection:
            // Reopen is offered as a button, not a shortcut, so the copy only
            // names Command-N to match the actual bound keys (INT-166 review:
            // the hint used to advertise Cmd-N for reopen, which nothing binds).
            if canReopenWorkspace {
                return LocalizedStringResource(
                    "Create a workspace with Command-N, or reopen the last one you closed.",
                    comment: "Empty-state guidance when a recently closed workspace can be reopened."
                )
            }
            return LocalizedStringResource(
                "Create a workspace with Command-N.",
                comment: "Empty-state guidance when no recently closed workspace can be reopened."
            )
        }
    }

    var body: some View {
        let accentColor = Color.aw.accent(accentResolver.accent)

        VStack(alignment: .leading, spacing: 16) {
            // Decorative — the heading below carries the product name, so hide
            // this from VoiceOver to avoid announcing "awesoMux" twice.
            Brandmark(size: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(heading)
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(accentColor)
                    .accessibilityAddTraits(.isHeader)

                Text(bodyText)
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
            }

            // ViewThatFits drops to a vertical stack at large Dynamic Type or
            // narrow widths, so neither button gets clipped past the 460pt cap.
            ViewThatFits(in: .horizontal) {
                actionButtons(axis: .horizontal)
                actionButtons(axis: .vertical)
            }
        }
        .padding(32)
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let the real children (heading, body, buttons) carry the spoken copy
        // rather than a container label/hint that can diverge from what's on
        // screen and be swallowed under `.contain` (INT-166 review).
        .accessibilityElement(children: .contain)
        .onAppear {
            // Single-shot — re-firing on every appear (e.g. sheet dismissal)
            // would yank VoiceOver focus from wherever the user just was.
            guard !didFocusInitial else { return }
            didFocusInitial = true
            primaryActionFocused = true
        }
    }

    @ViewBuilder
    private func actionButtons(axis: Axis) -> some View {
        let primary = Button {
            onNewWorkspace()
        } label: {
            Label("New Workspace", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .help("Create a new workspace")
        .accessibilityFocused($primaryActionFocused)

        // Hide (not disable) the reopen button when there's nothing to reopen:
        // a dimmed control's disabled-reason hint is unreliable under VoiceOver,
        // and the body copy already adapts to whether reopen is offered.
        switch axis {
        case .horizontal:
            HStack(spacing: 10) {
                primary
                if canReopenWorkspace { reopenButton }
            }
        case .vertical:
            VStack(alignment: .leading, spacing: 10) {
                primary
                if canReopenWorkspace { reopenButton }
            }
        }
    }

    private var reopenButton: some View {
        Button {
            onOpenRecent()
        } label: {
            Label("Reopen Closed Workspace", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .help("Reopen the most recently closed workspace (kept for 24 hours)")
    }
}

private struct NeedsInputBar: View {
    let session: TerminalSession
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(.needs)

            Text("permission needed")
                .awFont(AwFont.Mono.kicker)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.status.needs)
                .lineLimit(1)
                .layoutPriority(0)

            Text(session.title)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
                .layoutPriority(0)

            Spacer(minLength: 12)

            Button {
                onAcknowledge()
            } label: {
                Text("Acknowledge")
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.status.onLoud)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.aw.status.needs, in: RoundedRectangle(cornerRadius: AwRadius.pill))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help("\(KeyboardShortcutCatalog.acknowledgeWorkspace.action) (\(KeyboardShortcutCatalog.acknowledgeWorkspace.displaySymbol))")
            .accessibilityLabel("\(KeyboardShortcutCatalog.acknowledgeWorkspace.action), \(KeyboardShortcutCatalog.acknowledgeWorkspace.spokenForm)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(minHeight: 46)
        .background {
            LinearGradient(
                colors: [
                    Color.aw.status.needs.opacity(0.22),
                    Color.aw.status.needs.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .leading) { edgeAccent }
        .overlay(alignment: .trailing) { edgeAccent }
        .overlay(alignment: .top) { horizontalAccent }
        .overlay(alignment: .bottom) { horizontalAccent }
    }

    private var edgeAccent: some View { accentBar(width: 3) }
    private var horizontalAccent: some View { accentBar(height: 3) }

    // Decorative; state is already carried by StatusDot + the "permission
    // needed" text, same rationale as StatusDot's own accessibilityHidden use.
    private func accentBar(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle()
            .fill(Color.aw.status.needs)
            .frame(width: width, height: height)
            .awGlow(color: Color.aw.status.needs.opacity(0.7), radius: 7)
            .accessibilityHidden(true)
    }
}
