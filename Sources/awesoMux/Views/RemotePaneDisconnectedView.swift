import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The three-way overlay text/button content for `RemotePaneDisconnectedView`,
/// pulled out as a pure function so the label/enabled logic is testable
/// without standing up a view hierarchy (INT-697 §6).
struct RemotePaneDisconnectedContent {
    let title: String
    let description: String
    let buttonLabel: String
    let buttonEnabled: Bool

    /// - Parameters:
    ///   - state: the latched pane's `remoteReconnect` value.
    ///   - liveTarget: the pane's durable execution target read fresh at render
    ///     time. It may differ from the target captured in `state` after an
    ///     explicit pane retarget operation.
    static func make(
        state: RemoteReconnectState,
        liveTarget: RemoteTarget?,
        backgroundSessionsEnabled: Bool = true
    ) -> Self {
        let captured = state.context.target
        let buttonEnabled: Bool
        let isReconnecting: Bool
        switch state {
        case .disconnected:
            buttonEnabled = true
            isReconnecting = false
        case .reconnecting:
            buttonEnabled = false
            isReconnecting = true
        }

        if !backgroundSessionsEnabled, let liveTarget, !isReconnecting {
            return Self(
                title: String(
                    localized: "Background sessions are off",
                    comment: "Title on a managed SSH pane blocked because background terminal sessions are disabled"
                ),
                description: String(
                    localized: "Managed SSH requires background terminal sessions.",
                    comment: "Explanation on a managed SSH pane blocked because background terminal sessions are disabled"
                ),
                buttonLabel: String(
                    localized: "Enable and reconnect to \(liveTarget.host)",
                    comment: "Button that enables background terminal sessions and reconnects a managed SSH pane"
                ),
                buttonEnabled: true
            )
        }

        // While reconnecting, the title reflects the in-flight state so the
        // overlay isn't stuck reading "Disconnected" over a live retry (INT-697
        // fix #7).
        let title = isReconnecting
            ? String(
                localized: "Reconnecting…",
                comment: "Title on the remote-pane overlay while a manual reconnect is in flight"
            )
            : String(
                localized: "SSH connection failed",
                comment: "Title on the overlay covering a remote pane whose SSH connection failed or ended"
            )
        var description = String(
            localized: "Could not connect to \(captured.host), or the connection ended.",
            comment: "Description under the SSH connection failed overlay title, naming the remote host"
        )
        // If the session moved to a DIFFERENT remote host while latched, the
        // button names the live host but the description names the captured
        // one — spell out the move so the two hostnames aren't silently
        // contradictory (INT-697 fix #11).
        if let liveTarget, liveTarget.host != captured.host {
            description += "\n" + String(
                localized: "This workspace now targets \(liveTarget.host).",
                comment: "Second description line on the remote-disconnected overlay when the workspace moved to a different remote host than the one that dropped"
            )
        }
        if !isReconnecting {
            let diagnosticTarget = liveTarget ?? captured
            description +=
                "\n"
                + String(
                    localized: "Check that \(diagnosticTarget.host) is a valid hostname or SSH config alias and is reachable.",
                    comment: "Guidance shown after a managed SSH connection fails"
                )
                + "\n"
                + String(
                    localized: "For more details, try ssh \(diagnosticTarget.sshDestination) in a local workspace.",
                    comment: "Safe ordinary SSH diagnostic shown after a managed SSH connection fails"
                )
        }

        guard buttonEnabled else {
            let reconnectingLabel = String(
                localized: "Reconnecting…",
                comment: "Disabled button label shown on the remote-disconnected overlay while a manual reconnect is in flight"
            )
            return Self(title: title, description: description, buttonLabel: reconnectingLabel, buttonEnabled: false)
        }

        let buttonLabel: String
        if let liveTarget {
            // The LIVE target wins the label — it's what the reconnect attach
            // actually dials. If the session moved groups while latched, the
            // captured (disconnect-time) host and the live host can differ.
            buttonLabel = String(
                localized: "Reconnect to \(liveTarget.host)",
                comment: "Button label to reconnect a disconnected remote pane, naming the CURRENT live target host"
            )
        } else {
            buttonLabel = String(
                localized: "Restart pane",
                comment: "Button label on the remote-disconnected overlay when the pane's session has moved to a local group, so there is no remote host to reconnect to"
            )
        }
        return Self(title: title, description: description, buttonLabel: buttonLabel, buttonEnabled: true)
    }
}

/// Opaque overlay shown over a remote pane whose bridge died (INT-697). Gated
/// by the caller on `pane.remoteReconnect != nil` alone; this view only picks
/// the three-way content once shown. Borrows `RuntimeUnavailableView`'s shape
/// (ContentUnavailableView + prominent button + announce-once-on-appear) but
/// is an overlay above the surface region, not a whole-pane replacement.
struct RemotePaneDisconnectedView: View {
    let state: RemoteReconnectState
    let liveTarget: RemoteTarget?
    let runtime: GhosttyRuntime
    let paneID: TerminalPane.ID
    /// Tree-order pane descriptor for a split, computed by the caller (which
    /// has the session); nil in a single-pane session (INT-697 fix #8).
    let paneDescriptor: String?

    // Tracks the last disconnected state we announced, so a
    // `.disconnected` -> `.reconnecting` -> `.disconnected` (failed retry)
    // cycle on the SAME host re-announces (state resets to nil while
    // `.reconnecting`), mirroring `RuntimeUnavailableView.lastAnnouncedMessage`.
    @State private var lastAnnouncementID: String?

    // The button resolves its fill from the accent; reading the bare
    // `Color.aw.accent` global inside the representable establishes no SwiftUI
    // dependency, so a live accent change in Settings never re-ran
    // `updateNSView` (live smoke finding, PR #506). Passing the
    // environment-resolved accent down as an input does.
    @Environment(\.awAccent) private var accentResolver
    @Environment(AppSettingsStore.self) private var appSettingsStore

    private var capturedTarget: RemoteTarget {
        state.context.target
    }

    private var content: RemotePaneDisconnectedContent {
        .make(
            state: state,
            liveTarget: liveTarget,
            backgroundSessionsEnabled: appSettingsStore.terminal.value.commandBridgeEnabled
        )
    }

    private var isDisconnected: Bool {
        if case .disconnected = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.aw.surface.terminal)

            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label(content.title, systemImage: "wifi.slash")
                } description: {
                    Text(content.description)
                }
                .foregroundStyle(.secondary)

                // An NSButton with `refusesFirstResponder` rather than a SwiftUI
                // Button: a plain SwiftUI Button click over/near a ghostty pane
                // steals first responder and blanks the sibling pane's surface
                // (and breaks its reclaim-when-vacant path) — the INT-562/748
                // bug this repo fixed twice. Same precedent as `PaneCloseButton`
                // / the document `SendToAgentButton` (INT-697 fix #3a).
                RemoteReconnectButton(
                    title: content.buttonLabel,
                    isEnabled: content.buttonEnabled,
                    accent: accentResolver.accent
                ) {
                    if liveTarget != nil,
                        !appSettingsStore.terminal.value.commandBridgeEnabled
                    {
                        appSettingsStore.terminal.update { $0.commandBridgeEnabled = true }
                        guard appSettingsStore.terminal.value.commandBridgeEnabled else {
                            if let settingsErrorMessage {
                                TerminalAccessibilityAnnouncer.announce(settingsErrorMessage, priority: .high)
                            }
                            return
                        }
                    }
                    runtime.reconnectRemotePane(in: paneID)
                }
                .frame(height: 30)
                .fixedSize()

                if let settingsErrorMessage {
                    Text(settingsErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
        }
        // `.contain` (not `.combine`) so the button stays independently
        // keyboard/VoiceOver reachable — only the container itself gets the
        // extra descriptive label below (§5: the button must stay reachable).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(containerAccessibilityLabel)
        .task(id: announcementStateID) {
            announceDisconnectedIfNeeded()
        }
    }

    private var containerAccessibilityLabel: String {
        if needsBackgroundSessions {
            return String(
                localized: "Remote pane disconnected from \(capturedTarget.host). Background sessions are off.",
                comment: "Accessibility label for a managed SSH pane blocked because background terminal sessions are disabled"
            )
        }
        if isDisconnected {
            let failure = String(
                localized: "SSH connection to \(capturedTarget.host) failed.",
                comment: "Accessibility label for a remote pane whose SSH connection failed"
            )
            let guidance = String(
                localized: "Check that the hostname or SSH config alias exists and is reachable.",
                comment: "Accessibility guidance after a remote pane's SSH connection fails"
            )
            return failure + " " + guidance
        }
        return String(
            localized: "Remote pane reconnecting to \(capturedTarget.host)",
            comment: "Accessibility label for the overlay container while a remote pane's manual reconnect is in flight"
        )
    }

    private var needsBackgroundSessions: Bool {
        isDisconnected
            && liveTarget != nil
            && !appSettingsStore.terminal.value.commandBridgeEnabled
    }

    private var settingsErrorMessage: String? {
        needsBackgroundSessions ? appSettingsStore.latestError?.displayText : nil
    }

    private var announcementStateID: String {
        "\(capturedTarget.host)\u{0}\(isDisconnected)\u{0}\(needsBackgroundSessions)"
    }

    private func announceDisconnectedIfNeeded() {
        guard isDisconnected else {
            // `.reconnecting` (or a future non-disconnected case) clears the
            // guard so a subsequent re-latch on the SAME host announces again
            // instead of being silently deduped by stale state.
            lastAnnouncementID = nil
            return
        }

        let host = capturedTarget.host
        guard announcementStateID != lastAnnouncementID else { return }
        lastAnnouncementID = announcementStateID

        TerminalAccessibilityAnnouncer.announceRemoteDisconnected(
            host: host,
            paneDescriptor: paneDescriptor,
            backgroundSessionsEnabled: !needsBackgroundSessions
        )
    }
}

/// First-responder-safe reconnect button for `RemotePaneDisconnectedView`:
/// a titled, accent-filled `NSButton` with `refusesFirstResponder = true`, so
/// clicking it never steals focus from a sibling ghostty surface (INT-562/748).
/// Mirrors the document `SendToAgentButton` shape.
private struct RemoteReconnectButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    /// Environment-resolved by the parent — an input (unlike the bare
    /// `Color.aw.accent` global) so an accent change re-runs `updateNSView`.
    let accent: AwAccent
    let action: () -> Void

    /// A non-bordered NSButton hugs its title with no breathing room, so the
    /// accent fill renders as a tight pill around the text. Pad the intrinsic
    /// size so the layer background gets a real button footprint.
    private final class PaddedButton: NSButton {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += 48
            return size
        }
    }

    func makeNSView(context: Context) -> NSButton {
        let button = PaddedButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .noImage
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        nsView.isEnabled = isEnabled
        // Prominent (filled) when actionable, muted while disabled/reconnecting.
        let accentColor = Color.aw.accent(accent)
        let accentFill = NSColor(accentColor)
        nsView.layer?.backgroundColor = isEnabled
            ? accentFill.cgColor
            : accentFill.withAlphaComponent(0.25).cgColor
        nsView.attributedTitle = Self.makeTitle(title, enabled: isEnabled, accentFill: accentColor)
        nsView.setAccessibilityLabel(title)
        nsView.toolTip = title
    }

    private static func makeTitle(_ text: String, enabled: Bool, accentFill: Color) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        // Text on the accent fill picks black/white by the design system's
        // WCAG crossover — the default peach accent is LIGHT, so hardcoded
        // white text fails contrast on it (live smoke finding, PR #506).
        let onAccent: NSColor = Color.aw.backgroundIsDark(accentFill) ? .white : .black
        let color: NSColor = enabled ? onAccent : .secondaryLabelColor
        let result = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let glyph = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let attachment = NSTextAttachment()
            attachment.image = glyph
            attachment.bounds = CGRect(
                x: 0,
                y: (font.capHeight - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }

        result.append(NSAttributedString(string: text))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttributes(
            [.foregroundColor: color, .font: font, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
