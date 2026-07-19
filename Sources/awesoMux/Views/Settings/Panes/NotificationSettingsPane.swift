import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct NotificationSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(SessionStore.self) private var sessionStore
    @State private var authorizationModel = NotificationAuthorizationModel()
    @State private var isDockBounceConfirmationPresented = false

    private var muted: Bool {
        appSettingsStore.notifications.value.muted
    }

    // Shared between the visible hint column and the toggles' accessibility
    // hints, which append muted-state context the visible column doesn't need
    // (a sighted user sees the dimmed switch next to the Mute toggle).
    private static let soundHint = "Play the default notification sound."
    private static let needsInputHint = "Banner appears when a workspace surfaces a needs-attention signal."
    private static let dockBounceHint = "Bounce when a workspace needs you."
    private static let turnDoneHint = "Banner appears when an agent finishes its turn and is waiting for your next message."
    private static let turnDoneFocusedHint = "Also play a sound for the workspace you're currently viewing when its agent finishes a turn."
    private static let workspaceDetailsHint = "Includes workspace names and project context in macOS notification previews."

    private var dockBounceUnavailable: Bool {
        muted
            || !appSettingsStore.notifications.value.notifyOnNeedsAttention
    }

    private var turnDoneDisabled: Bool {
        muted || !appSettingsStore.notifications.value.notifyOnTurnDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: "Delivery",
                subtitle: "Banner notifications for agent attention and workspace events."
            ) {
                SettingsField(
                    label: "Mute notifications",
                    hint: "Suppresses every notification awesoMux would otherwise deliver.",
                    isFirst: true,
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Mute notifications", isOn: appSettingsStore.notifications.binding(\.muted))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: "Sound",
                    hint: Self.soundHint,
                    forwardsAccessibilityToControl: true,
                    // The toggle carries its own muted-aware hint below; letting
                    // the field forward its static hint would replace it and drop
                    // the disabled-state context (WCAG 1.3.1).
                    forwardsHintToControl: false
                ) {
                    Toggle("Sound", isOn: appSettingsStore.notifications.binding(\.sound))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(muted)
                        .accessibilityHint(mutedAwareHint(Self.soundHint))
                }

                SettingsField(
                    label: "During Focus",
                    hint: focusBehaviorHint
                ) {
                    Picker(
                        "During Focus",
                        selection: appSettingsStore.notifications.binding(\.respectDoNotDisturb)
                    ) {
                        Text("Keep awesoMux quiet").tag(true)
                        Text("Let awesoMux get my attention").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .disabled(muted)
                    .accessibilityLabel("During Focus")
                    .accessibilityHint(mutedAwareHint(focusBehaviorHint))
                }

                SettingsField(
                    label: "Notify when an agent needs input",
                    hint: Self.needsInputHint,
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    Toggle("Notify when an agent needs input", isOn: appSettingsStore.notifications.binding(\.notifyOnNeedsAttention))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(muted)
                        .accessibilityHint(mutedAwareHint(Self.needsInputHint))
                }

                SettingsField(
                    label: "Bounce Dock icon",
                    hint: dockBounceAwareHint
                ) {
                    if appSettingsStore.notifications.value.respectDoNotDisturb, !dockBounceUnavailable {
                        Button("Enable…") {
                            isDockBounceConfirmationPresented = true
                        }
                        .accessibilityLabel("Enable Dock bouncing")
                        .accessibilityHint(Text(dockBounceAwareHint))
                    } else {
                        Toggle("Bounce Dock icon", isOn: appSettingsStore.notifications.binding(\.dockBounceOnNeedsAttention))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(dockBounceUnavailable)
                            .accessibilityLabel("Bounce Dock icon")
                            .accessibilityHint(Text(dockBounceAwareHint))
                    }
                }

                SettingsField(
                    label: "Notify when my turn is done",
                    hint: Self.turnDoneHint,
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    Toggle("Notify when my turn is done", isOn: appSettingsStore.notifications.binding(\.notifyOnTurnDone))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(muted)
                        .accessibilityHint(mutedAwareHint(Self.turnDoneHint))
                }

                SettingsField(
                    label: "Alert for the focused workspace too",
                    hint: Self.turnDoneFocusedHint,
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    Toggle("Alert for the focused workspace too", isOn: appSettingsStore.notifications.binding(\.turnDoneAlertsWhenFocused))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(turnDoneDisabled)
                        .accessibilityHint(turnDoneFocusedAwareHint(Self.turnDoneFocusedHint))
                }

                SettingsField(
                    label: "Show workspace details",
                    hint: Self.workspaceDetailsHint,
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    Toggle("Show workspace details", isOn: appSettingsStore.notifications.binding(\.showWorkspaceDetails))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(muted)
                        .accessibilityHint(mutedAwareHint(Self.workspaceDetailsHint))
                }
            }

            SettingsSection(
                index: 2,
                title: "macOS permission",
                subtitle: "Banner and sound delivery requires macOS notification permission."
            ) {
                SettingsField(
                    label: "Permission status",
                    hint: permissionHint,
                    isFirst: true
                ) {
                    permissionStatusBadge
                }

                if authorizationModel.status == .denied {
                    SettingsField(
                        label: "Fix in System Settings",
                        hint: "In System Settings → Notifications, select awesoMux and turn Allow Notifications back on."
                    ) {
                        Button("Open System Settings") {
                            authorizationModel.openSystemNotificationSettings()
                        }
                        .accessibilityHint("Opens the macOS Notifications settings pane for awesoMux.")
                    }
                }
            }

            SettingsSection(
                index: 3,
                title: "Per-workspace mute",
                subtitle:
                    "Muted workspaces skip macOS banners, sound, and Dock bounces but keep their sidebar indicators, unread badges, and dock-badge count. Per-workspace mute is local to this machine."
            ) {
                SettingsField(
                    label: "Muted workspaces",
                    hint: mutedWorkspaces.isEmpty
                        ? "No workspace overrides. Right-click a workspace in the sidebar and choose Mute Notifications."
                        : "Unmute restores macOS banners, sound, and Dock bounces for that workspace.",
                    isFirst: true
                ) {
                    mutedWorkspacesList
                }
            }
        }
        .onAppear {
            authorizationModel.refresh()
        }
        // The likely flow is: user sees "denied", jumps to System Settings,
        // flips the toggle, and comes back — refresh on re-activation so the
        // pane reflects the fix without a relaunch.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            authorizationModel.refresh()
        }
        .confirmationDialog(
            "Turn on Dock bouncing?",
            isPresented: $isDockBounceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Turn On") {
                appSettingsStore.notifications.update { notifications in
                    notifications.respectDoNotDisturb = false
                    notifications.dockBounceOnNeedsAttention = true
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(
                "Focus can quiet notifications, but it can’t stop Dock bounces. To use this, awesoMux will need to get your attention even when Focus is on."
            )
        }
    }

    private var mutedWorkspaces: [TerminalSession] {
        sessionStore.mutedNotificationSessions
    }

    @ViewBuilder
    private var mutedWorkspacesList: some View {
        if mutedWorkspaces.isEmpty {
            Text("No workspace overrides")
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(mutedWorkspaces) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.aw.text2)
                            .accessibilityHidden(true)
                        Text(session.title)
                            .awFont(AwFont.UI.label)
                            .foregroundStyle(Color.aw.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Unmute") {
                            sessionStore.setNotificationsMuted(id: session.id, muted: false)
                        }
                        .accessibilityLabel("Unmute notifications for \(session.title)")
                    }
                }
            }
        }
    }

    private var permissionHint: String {
        switch authorizationModel.status {
        case .authorized:
            "macOS allows awesoMux banners, sounds, and badges."
        case .denied:
            "macOS is blocking awesoMux notifications, so attention banners will not appear. macOS only shows the permission dialog once, so this can only be fixed in System Settings."
        case .notDetermined:
            "macOS has not been asked yet. awesoMux requests permission when it first needs to notify you."
        case .unknown:
            "Checking the macOS notification permission…"
        }
    }

    private var permissionStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(permissionStatusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(permissionStatusLabel)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("macOS notification permission: \(permissionStatusLabel)")
    }

    private var permissionStatusLabel: String {
        switch authorizationModel.status {
        case .authorized:
            String(localized: "Allowed", comment: "Settings label when macOS notification permission is granted.")
        case .denied:
            String(localized: "Denied", comment: "Settings label when macOS notification permission is denied.")
        case .notDetermined:
            String(localized: "Not requested yet", comment: "Settings label when macOS notification permission has not been requested.")
        case .unknown:
            String(localized: "Checking…", comment: "Settings label while the macOS notification permission state is being fetched.")
        }
    }

    private var permissionStatusColor: Color {
        switch authorizationModel.status {
        case .authorized:
            Color.aw.status.output
        case .denied:
            Color.aw.status.needs
        case .notDetermined, .unknown:
            Color.aw.text3
        }
    }

    /// Base hint, plus the reason the switch is dimmed while muted — VoiceOver
    /// users can't see the dimming, and a nameless disabled state fails
    /// WCAG 1.3.1.
    private func mutedAwareHint(_ base: String) -> Text {
        Text(muted ? base + " " + String(localized: "Unavailable while notifications are muted.") : base)
    }

    private var focusBehaviorHint: String {
        if appSettingsStore.notifications.value.respectDoNotDisturb {
            return String(localized: "No notification banners or sounds, and the Dock icon won’t bounce.")
        }
        return String(localized: "Notification banners and sounds can come through, and you can turn on Dock bouncing.")
    }

    private var dockBounceAwareHint: String {
        if muted {
            return Self.dockBounceHint + " " + String(localized: "Unavailable while notifications are muted.")
        }
        if !appSettingsStore.notifications.value.notifyOnNeedsAttention {
            return Self.dockBounceHint + " " + String(localized: "Turn on “Notify when an agent needs input” to enable this.")
        }
        if appSettingsStore.notifications.value.respectDoNotDisturb {
            return Self.dockBounceHint + " " + String(localized: "Choose “Let awesoMux get my attention” to turn this on.")
        }
        return Self.dockBounceHint
    }

    /// Like `mutedAwareHint`, but the focused sub-option dims for two reasons —
    /// muted OR the parent turn-done toggle being off (`turnDoneDisabled`). A
    /// VoiceOver user can't see the dimming, so name whichever reason applies;
    /// the parent-off clause also speaks the dependency a sighted user only
    /// infers from layout proximity (WCAG 1.3.1).
    private func turnDoneFocusedAwareHint(_ base: String) -> Text {
        if muted {
            return Text(base + " " + String(localized: "Unavailable while notifications are muted."))
        }
        if !appSettingsStore.notifications.value.notifyOnTurnDone {
            return Text(base + " " + String(localized: "Turn on “Notify when my turn is done” to enable this."))
        }
        return Text(base)
    }
}
