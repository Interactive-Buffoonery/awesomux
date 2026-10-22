import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct LocalPermissionPromptView: View {
    @Bindable var coordinator: LocalPermissionCoordinator
    let paneID: UUID
    let onFocusReturned: () -> Void
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool
    @State private var focusGrant: LocalPermissionIdentity?
    @State private var monitor = LocalPermissionKeyMonitor()

    var body: some View {
        Group {
            if let card = coordinator.cards[paneID] {
                let identity = card.request.identity
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(status(card.outcome.state))
                            .awFont(AwFont.Mono.kicker)
                        Spacer()
                        if card.outcome.state == .pending {
                            PermissionActionButton(
                                title: String(
                                    localized: "Deny once", comment: "Deny this Claude permission request only; do not remember a grant."),
                                accessibilityLabel: String(
                                    localized: "Deny once. Escape when focused.",
                                    comment: "Accessible deny action; Escape acts only after deliberate permission-card focus."),
                                tint: Color.aw.text,
                                action: { coordinator.decide(identity, choice: .deny) }
                            ).frame(minWidth: 24, minHeight: 24)
                            PermissionActionButton(
                                title: String(
                                    localized: "Allow once", comment: "Allow this Claude permission request only; do not remember a grant."),
                                accessibilityLabel: String(
                                    localized: "Allow once. Command-Return when focused.",
                                    comment: "Accessible allow action; Command-Return acts only after deliberate permission-card focus."),
                                tint: Color.aw.status.needs,
                                action: { coordinator.decide(identity, choice: .allow) }
                            ).frame(minWidth: 24, minHeight: 24)
                        }
                    }
                    if let count = coordinator.queuedCounts[paneID], count > 0 {
                        Text(LocalizedPluralStrings.bridgePermissionQueuedCount(count: count))
                            .awFont(AwFont.Mono.meta)
                    }
                    ConsentTextView(text: card.request.tool, maximumHeight: 60)
                        .awFont(AwFont.Mono.meta)
                    if BridgePermissionPromptView.hasSuspiciousText(tool: card.request.tool, target: card.request.summary, summary: nil) {
                        Text("Warning: this request mixes character scripts and may be disguised.")
                            .awFont(AwFont.Mono.meta)
                    }
                    ConsentTextView(text: card.request.summary, maximumHeight: 120)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text)
                    if card.outcome.choice != nil {
                        Text(LocalPermissionCoordinator.recordedMessage(card.outcome))
                            .awFont(AwFont.Mono.meta)
                    }
                    Text("Untrusted tool request · revision \(identity.revision)")
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text)
                    Text("Claude’s own prompt may still be answered in the terminal.")
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text)
                }
                .id(identity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.aw.status.needs.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.aw.text, lineWidth: 2)
                        .opacity(focused ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityFocused($accessibilityFocused)
                .accessibilityActions {
                    if card.outcome.state == .pending {
                        Button("Allow once") { coordinator.decide(identity, choice: .allow) }
                        Button("Deny once") { coordinator.decide(identity, choice: .deny) }
                    }
                }
                .focusable(true)
                .focusEffectDisabled()
                .focused($focused)
            }
        }
        .onChange(of: coordinator.focusRequest?.token) {
            guard coordinator.focusRequest?.paneID == paneID,
                let card = coordinator.cards[paneID], card.outcome.state == .pending
            else { return }
            focusGrant = card.request.identity
            focused = true
            accessibilityFocused = true
            monitor.start(coordinator: coordinator, identity: card.request.identity)
        }
        .onChange(of: focused) { _, value in
            if !value { focusGrant = nil; monitor.stop() }
        }
        .onChange(of: coordinator.cards[paneID]) { previous, current in
            if previous?.request.identity != current?.request.identity || current?.outcome.state != .pending {
                clearFocus()
            }
        }
        .onDisappear { clearFocus() }
    }

    private func clearFocus() {
        let ownedFocus = focusGrant != nil && focused
        focusGrant = nil
        focused = false
        accessibilityFocused = false
        monitor.stop()
        if ownedFocus { DispatchQueue.main.async { onFocusReturned() } }
    }

    private func status(_ state: LocalPermissionState) -> String {
        switch state {
        case .pending:
            String(localized: "Claude permission needed", comment: "A local Claude hook is waiting for a one-time permission decision.")
        case .recorded:
            String(
                localized: "Answer recorded on Mac", comment: "The Mac recorded the decision; delivery to the hook is not yet confirmed.")
        case .delivering:
            String(localized: "Returning answer to Claude", comment: "The recorded decision is being delivered to the Claude hook.")
        case .delivered:
            String(
                localized: "Answer delivered to Claude hook",
                comment: "The hook acknowledged the answer; this does not confirm tool execution.")
        case .cancelled:
            String(
                localized: "Permission request cancelled",
                comment: "The local permission request was cancelled and cannot receive another decision.")
        case .expired:
            String(
                localized: "Permission request expired",
                comment: "The local permission request expired; the hook falls through to the native prompt.")
        case .unknown:
            String(
                localized: "Permission delivery unknown",
                comment: "Delivery of the recorded decision is uncertain; do not retry or imply tool execution.")
        }
    }
}

@MainActor
private final class LocalPermissionKeyMonitor {
    private var token: Any?

    func start(coordinator: LocalPermissionCoordinator, identity: LocalPermissionIdentity) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator,
                coordinator.cards[identity.target.paneID]?.request.identity == identity,
                coordinator.cards[identity.target.paneID]?.outcome.state == .pending
            else { return event }
            switch BridgePermissionPromptKey.action(forKeyCode: event.keyCode, modifierFlags: event.modifierFlags, focused: true) {
            case .allow: coordinator.decide(identity, choice: .allow); return nil
            case .deny: coordinator.decide(identity, choice: .deny); return nil
            case nil: return event
            }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    isolated deinit { stop() }
}
