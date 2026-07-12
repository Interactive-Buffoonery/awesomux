import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI
import UnicodeHygiene

/// The in-pane permission banner (INT-698, binding contributor ruling): a
/// `NeedsInputBar`-style strip on the remote pane showing the requested tool +
/// target, Allow/Deny buttons, and a queue badge when more prompts wait. Not a
/// floating card, not activity-panel-only.
///
/// **Accessibility contract (spec §"Accessibility contract"), enforced here:**
/// - **Arrival never steals focus.** The banner self-gates on
///   `coordinator.activePrompt`; it is not made first responder on appear, so a
///   prompt landing mid-keystroke leaves the terminal's first responder intact.
/// - **Allow/Deny are `NSButton`s with `refusesFirstResponder`.** A SwiftUI
///   `Button` next to a ghostty surface steals first responder on click and
///   blanks the surface (documented repo gotcha; see `PaneCloseButton`). These
///   buttons never take first responder — clicking Allow/Deny doesn't blank the
///   terminal — while VoiceOver still activates them via the AX tree (which does
///   not require first responder).
/// - **Bare Return/default never maps to Allow — inviolable.** There is no
///   `.defaultAction`, no `.keyboardShortcut`, no default button anywhere in
///   this view. Bare Return (36) and keypad Enter (76) map to nothing, always,
///   focused or not. The one keyboard path to Allow is ⌘⏎ or the plain `A` key,
///   and only while the prompt is deliberately focused via
///   `focusPermissionPrompt` (USER RULING, INT-698 addendum) — never reachable
///   by a stray keystroke aimed at the terminal. Escape→deny works focused or
///   not, via `BridgePermissionPromptKey`.
/// - **Escape denies via the early-deny path**, through a scoped local
///   `NSEvent` key monitor active only while the banner is deliberately focused
///   (the documented-gotcha alternative to `.onExitCommand`) — so a terminal
///   user's Escape (vim) is untouched until they move focus to the prompt.
/// - **Full `target` reaches assistive tech** even when the visible text elides,
///   via the accessibility label. The queued count is exposed to AT through the
///   stringsdict plural and shown as a badge.
struct BridgePermissionPromptView: View {
    @Bindable var coordinator: BridgePermissionCoordinator

    @AccessibilityFocusState private var promptAccessibilityFocused: Bool
    @FocusState private var bannerFocused: Bool
    @State private var keyMonitor = BridgePermissionKeyMonitor()

    var body: some View {
        if let prompt = coordinator.activePrompt {
            banner(prompt)
                // The deliberate, user-initiated focus move — the ONLY time the
                // banner grabs focus. Bumped by `requestFocus()` (the palette /
                // shortcut command), never on arrival.
                .onChange(of: coordinator.focusRequestToken) {
                    bannerFocused = true
                    promptAccessibilityFocused = true
                }
                // Escape monitor is live only while the banner is deliberately
                // focused, so a terminal user's Escape stays with the terminal
                // until they move focus here.
                .onChange(of: bannerFocused) { _, focused in
                    if focused {
                        keyMonitor.start(coordinator: coordinator)
                    } else {
                        keyMonitor.stop()
                        // Focus returned to the terminal (Tab/click away) —
                        // clear the coordinator's own focused flag directly.
                        // Don't rely on SwiftUI resetting `bannerFocused` on
                        // the banner's disappear/reappear cycle across
                        // prompts to keep this in sync; that's a stale-state
                        // risk, so the coordinator's flag has its own
                        // explicit clear here as well as in `publish()`.
                        coordinator.clearPromptFocus()
                    }
                }
                .onDisappear { keyMonitor.stop() }
        }
    }

    @ViewBuilder
    private func banner(_ prompt: BridgePermissionCoordinator.ActivePrompt) -> some View {
        HStack(spacing: 12) {
            StatusDot(.needs)
                // Decorative: meaning is in the description element + buttons.
                // Leaving it visible under `.contain` parked VO on an unlabeled
                // graphic (accessibility review finding B3).
                .accessibilityHidden(true)

            Text("permission needed")
                .awFont(AwFont.Mono.kicker)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
                .layoutPriority(0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.tool)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if Self.hasSuspiciousText(tool: prompt.tool, target: prompt.target, summary: prompt.summary) {
                        // Homograph-spoof signal: the request text mixes writing
                        // systems, so the visible target may be a disguised
                        // command. Surface it — never reject (legit single-script
                        // non-Latin paths are valid). The warning is also in the
                        // container's AX label; hidden here to avoid a double read.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.aw.status.needs)
                            .help(String(
                                localized: "This request mixes character scripts and may be disguised.",
                                comment: "Tooltip on the remote permission banner warning that the request text mixes writing systems (a homograph-spoof signal)"
                            ))
                            .accessibilityHidden(true)
                    }
                    Text(prompt.target)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text2)
                        // Elide visually; the full target reaches AT via the label
                        // below and sighted mouse users via the tooltip.
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(prompt.target)
                }
            }
            .layoutPriority(1)
            // One AX element carrying the FULL (never elided) target, so the
            // confused-deputy defense holds; the Allow/Deny buttons stay as their
            // OWN reachable AX elements via the container's `.contain` below.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.accessibilityLabel(
                    tool: prompt.tool,
                    target: prompt.target,
                    summary: prompt.summary,
                    queuedCount: coordinator.queuedCount
                )
            )
            .accessibilityFocused($promptAccessibilityFocused)

            Spacer(minLength: 12)

            if coordinator.queuedCount > 0 {
                queueBadge(coordinator.queuedCount)
            }

            PermissionActionButton(
                title: String(localized: "Deny", comment: "Button that denies a remote agent's permission request"),
                accessibilityLabel: String(
                    localized: "Deny permission request. Escape when focused.",
                    comment: "Accessibility label for the deny button on the remote permission banner, including keyboard shortcut"
                ),
                tint: Color.aw.text,
                action: { coordinator.deny(id: prompt.id) }
            )
            // 24×24 minimum hit target (WCAG 2.5.8), matching PaneCloseButton —
            // the `.rounded` bezel renders under 24pt tall by default and the
            // row's 46pt minHeight only centers the shrunk button, it doesn't
            // grow it.
            .frame(minWidth: 24, minHeight: 24)
            .help(String(
                localized: "Deny (Escape when focused)",
                comment: "Tooltip for the deny button on the remote permission banner"
            ))
            .layoutPriority(1)

            PermissionActionButton(
                title: String(localized: "Allow", comment: "Button that allows a remote agent's permission request"),
                accessibilityLabel: String(
                    localized: "Allow permission request. Command-Return when focused.",
                    comment: "Accessibility label for the allow button on the remote permission banner, including keyboard shortcut"
                ),
                tint: Color.aw.status.needs,
                action: { coordinator.allow(id: prompt.id) }
            )
            .frame(minWidth: 24, minHeight: 24)
            .help(String(
                localized: "Allow (Command-Return when focused)",
                comment: "Tooltip for the allow button on the remote permission banner"
            ))
            .layoutPriority(1)
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
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.aw.status.needs.opacity(0.45))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .overlay {
            // Focus indicator (WCAG 2.4.11 Focus Appearance): a CONTRASTING
            // outline, not a same-hue bar over the same-hue `status.needs`
            // background. Drawn only on the deliberate focus move, never on
            // arrival.
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.aw.text, lineWidth: 2)
                .opacity(bannerFocused ? 1 : 0)
                .accessibilityHidden(true)
        }
        // `.contain` (NOT `.combine`): the full-target description element above
        // and the two Allow/Deny buttons all stay individually reachable and
        // activatable by VoiceOver and Full Keyboard Access. `.combine` collapsed
        // them into ONE element with no actions — pointer-only, the exact failure
        // this avoids.
        .accessibilityElement(children: .contain)
        // Belt-and-braces VoiceOver rotor actions so Allow/Deny are operable even
        // if a reader doesn't surface the representable buttons directly. Neither
        // is a default action — Return still can never allow.
        .accessibilityAction(named: Text("Allow")) { coordinator.allow(id: prompt.id) }
        .accessibilityAction(named: Text("Deny")) { coordinator.deny(id: prompt.id) }
        .focusable(true)
        .focusEffectDisabled()
        .focused($bannerFocused)
    }

    private func queueBadge(_ count: Int) -> some View {
        Text("\(count)")
            .awFont(AwFont.UI.label)
            .foregroundStyle(Color.aw.status.onLoud)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            // Solid `needs`, not a translucent tint: over the near-white Latte
            // surface a 0.6-opacity pill washed out to ~3:1 against the white
            // `onLoud` digit — below the WCAG AA text floor. The solid fill is
            // what every other status badge uses and what AwColorTests locks at
            // 4.5:1.
            .background(Color.aw.status.needs, in: Capsule())
            // The count is already in the banner's primary label (which every
            // VoiceOver user hears); hiding the badge avoids speaking it twice
            // on an element-by-element pass without risking it being missed by
            // a user who never navigates to the badge (review finding).
            .accessibilityHidden(true)
    }

    /// Full spoken description — tool, the complete (never elided) target, the
    /// optional summary, and the queued count. Pure and `static` so a test can
    /// assert the full target survives without hosting the view.
    static func accessibilityLabel(
        tool: String,
        target: String,
        summary: String?,
        queuedCount: Int
    ) -> String {
        var parts = [
            String(
                localized: "Permission requested: \(tool), \(target).",
                comment: "Accessibility label for the remote permission banner. Arguments: tool name, full requested target."
            )
        ]
        if let summary, !summary.isEmpty {
            parts.append(summary)
        }
        if hasSuspiciousText(tool: tool, target: target, summary: summary) {
            parts.append(String(
                localized: "Warning: this request mixes character scripts and may be disguised.",
                comment: "Accessibility warning appended to the remote permission banner when the request text mixes writing systems (a homograph-spoof signal)"
            ))
        }
        if queuedCount > 0 {
            parts.append(LocalizedPluralStrings.bridgePermissionQueuedCount(count: queuedCount))
        }
        return parts.joined(separator: " ")
    }

    /// True when any free-text field mixes letters from more than one of the
    /// Latin/Cyrillic/Greek families — the classic homograph spoof, e.g. a
    /// `target` disguising a dangerous command with a Cyrillic lookalike. The
    /// bridge parser already strips invisible/bidi scalars, but confusable
    /// letters render legitimately, so this is only SURFACED to the user (a
    /// warning glyph and the AX phrase above) — never used to reject, since a
    /// genuinely single-script non-Latin path is valid. `static` and pure so a
    /// test can exercise it without hosting the view.
    static func hasSuspiciousText(tool: String, target: String, summary: String?) -> Bool {
        UnicodeHygiene.hasSuspiciousScriptMixing(tool)
            || UnicodeHygiene.hasSuspiciousScriptMixing(target)
            || (summary.map(UnicodeHygiene.hasSuspiciousScriptMixing) ?? false)
    }
}

/// The key mapping the banner honors. Escape denies (the early-deny path)
/// unconditionally, focused or not. Bare Return (36) and keypad Enter (76)
/// NEVER map to anything — that half of "Return never maps to Allow" is
/// inviolable and does not depend on `focused`. The one keyboard path to
/// Allow is ⌘⏎ or the plain `A` key (keyCode 0), and ONLY when `focused` is
/// `true` — the coordinator sets that only when the user deliberately focused
/// the prompt via `focusPermissionPrompt` (USER RULING, INT-698 addendum), so
/// it is never reachable by a stray keystroke aimed at the terminal. Pure and
/// testable — keyCode + modifiers + focused-flag in, action out; the
/// enforcement is one function, not scattered view modifiers.
enum BridgePermissionPromptKey {
    enum Action: Equatable {
        case allow
        case deny
    }

    static func action(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        focused: Bool = false
    ) -> Action? {
        switch keyCode {
        case 53: // Escape — always, focused or not
            return .deny
        case 36 where focused && modifierFlags.contains(.command): // ⌘Return, focused only
            return .allow
        case 0 where focused && modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            // The physical A-position key (keyCode, not character), focused
            // only. Deliberately position-based, not `charactersIgnoringModifiers
            // == "a"`: a keyCode is present on every layout, so this secondary
            // shortcut stays available on Cyrillic/Greek/CJK layouts whose
            // A-position key emits no "a" at all. The cost is that on AZERTY the
            // mnemonic sits under the physically-A key (their Q), which is
            // acceptable — ⌘Return is the layout-independent primary Allow path,
            // and this arm is gated behind deliberate prompt focus regardless.
            return .allow
        default:
            return nil
        }
    }
}

/// Owns the scoped local `NSEvent` key monitor's lifetime. Installed only while
/// the banner is deliberately focused; removed on unfocus/disappear. A separate
/// object (not a raw `@State Any?`) so start/stop are explicit and idempotent.
@MainActor
final class BridgePermissionKeyMonitor {
    /// `nonisolated(unsafe)` so the best-effort `deinit` (nonisolated) can read
    /// it. The token is an opaque AppKit monitor handle touched only on main; the
    /// unsafety is confined to handing it straight back to `removeMonitor`.
    nonisolated(unsafe) private var token: Any?
    /// Held weakly so a monitor that outlives view cleanup (SwiftUI does not
    /// guarantee `onDisappear` on every teardown path) neither retains the
    /// coordinator nor denies Escape app-wide — a leaked monitor stays inert.
    private weak var coordinator: BridgePermissionCoordinator?

    func start(coordinator: BridgePermissionCoordinator) {
        stop()
        self.coordinator = coordinator
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let coordinator = self.coordinator else {
                // Torn down but the monitor outlived cleanup: pass the event
                // through and self-remove so a leak can't keep intercepting keys.
                self?.stop()
                return event
            }
            switch BridgePermissionPromptKey.action(
                forKeyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                focused: coordinator.promptFocused
            ) {
            case .deny:
                coordinator.denyActive()
                return nil // consume Escape so it doesn't also reach the terminal
            case .allow:
                coordinator.allowActive()
                return nil // consume ⌘⏎/A so it doesn't also reach the terminal
            case nil:
                return event // pass everything else through untouched
            }
        }
    }

    func stop() {
        coordinator = nil
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }

    deinit {
        // Best-effort net; `.onDisappear`/unfocus is the primary cleanup and a
        // leaked monitor is already inert (weak coordinator). `removeMonitor` is
        // main-thread API, so hop when a `@MainActor` deinit runs off-main. The
        // token is an opaque AppKit handle — `nonisolated(unsafe)` launders it
        // across the boundary; it is only ever handed straight back to AppKit.
        guard let handle = token else { return }
        if Thread.isMainThread {
            NSEvent.removeMonitor(handle)
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(handle) }
        }
    }
}

/// An Allow/Deny button that never takes first responder — the ghostty-surface
/// focus-safety requirement (see `PaneCloseButton` for the same pattern and the
/// blank-surface gotcha it avoids). Deliberately NOT the app's default button:
/// no key equivalent, so Return can never trigger Allow.
private struct PermissionActionButton: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let tint: Color
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = title
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.refusesFirstResponder = true
        // No `keyEquivalent` — never the default button. A "\r" here would make
        // Return trigger it, the exact thing the accessibility contract forbids.
        button.keyEquivalent = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.contentTintColor = NSColor(tint)
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        if nsView.title != title {
            nsView.title = title
        }
        if nsView.toolTip != accessibilityLabel {
            nsView.setAccessibilityLabel(accessibilityLabel)
            nsView.toolTip = accessibilityLabel
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func fire() {
            action()
        }
    }
}
