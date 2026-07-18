import SwiftUI

/// SwiftUI content for an awesoMux modal.
public struct AwModalView<Content: View>: View {
    private let configuration: AwModalConfiguration
    private let content: Content
    private let onDecision: (AwModalDecision) -> Void

    @AccessibilityFocusState private var cancelButtonFocused: Bool
    @FocusState private var cancelButtonKeyFocused: Bool
    @State private var didRequestInitialFocus = false

    private var cornerRadius: CGFloat { 14 }
    private var maxWidth: CGFloat { 420 }
    private var minWidth: CGFloat { 320 }

    /// Creates a modal view with custom content between the body and buttons.
    public init(
        configuration: AwModalConfiguration,
        @ViewBuilder content: () -> Content,
        onDecision: @escaping (AwModalDecision) -> Void
    ) {
        self.configuration = configuration
        self.content = content()
        self.onDecision = onDecision
    }

    /// The modal content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(configuration.title)
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(configuration.body)
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(keyboardHintText)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    // VoiceOver's rendering of U+2318 in free text is
                    // unreliable; speak the spelled-out chord instead.
                    .accessibilityLabel(spokenKeyboardHintText)
            }

            content

            buttons
        }
        .padding(AwSpacing.panelPadding)
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                // Snapshot-only: AwModal is hosted in a bare NSHostingController and reads the live accent mailbox per summon.
                .stroke(Color.aw.accent.opacity(0.16), lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.aw.surface.chrome)
                // .overlay, not .sheet: over the transparent borderless panel a
                // heavy sheet shadow (r28 / y22 / 0.30) painted onto the dark
                // terminal reads as a second "outer card" around the real one.
                // The lighter overlay drop (r16 / y10 / 0.24) reads as one
                // floating panel.
                .awShadow(.overlay)
        }
        // The borderless panel clips to its frame, and AwModal sizes it to
        // this view's fittingSize — inset by the overlay-shadow spread
        // (radius 16, y-offset 10: ~16 to the sides, ~6 up, ~26 down) plus a
        // deliberately asymmetric safety margin (+6 sides/bottom, +10 top so
        // the sheet-anchored variant keeps a visible gap under the title bar)
        // so the shadow isn't truncated. This inset is pure shadow-reserve:
        // under reduce-transparency / increased-contrast awShadow drops the
        // shadow entirely, leaving inert transparent margin (the card sits a
        // few points above the panel's center) — harmless.
        .padding(EdgeInsets(top: 16, leading: 22, bottom: 32, trailing: 22))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .onAppear(perform: announceAndFocusCancelButton)
    }

    private var panelBackground: some View {
        Color.aw.surface.chrome
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 12)

            confirmButton
            cancelButton
        }
    }

    private var confirmButton: some View {
        Button(role: configuration.isConfirmDestructive ? .destructive : nil) {
            onDecision(.confirm)
        } label: {
            Text(configuration.confirmTitle)
                .awFont(AwFont.UI.label)
                .foregroundStyle(configuration.isConfirmDestructive ? Color.aw.red : Color.aw.text2)
        }
        .buttonStyle(.bordered)
        // No red .tint on the destructive branch: a red tint washes the
        // bordered bezel to near-invisible on the dark chrome, so Open reads
        // as disabled. A neutral bezel keeps it clearly an enabled, tappable
        // control while the red label carries the danger cue; Cancel's filled
        // accent keeps the emphasis. Pinned to the neutral text3 token rather
        // than left unset — an unset tint falls back to the user's SYSTEM
        // accent, and a Red system accent would reproduce the washed-red bezel
        // this fixes (same .tint-token pattern as SidebarStatusFooter's help
        // menu). The non-destructive branch (no production caller today) keeps
        // the app accent tint.
        // ponytail: leans on the native macOS 15 bordered bezel reading as
        // enabled under a neutral tint; if a future min-OS renders the
        // destructive-role bezel too subtly, upgrade to a scoped bordered style
        // built from AwColor/AwRadius tokens (keep the Button role).
        .tint(configuration.isConfirmDestructive ? Color.aw.text3 : Color.aw.accent)
        // No .keyboardShortcut here: the ⌘Return/keypad-Enter accept chord is
        // intercepted at the ModalPanel window level (AwModal.swift), which
        // covers keypad Enter and destructive-role buttons uniformly.
        .accessibilityLabel(configuration.confirmAccessibilityLabel ?? configuration.confirmTitle)
    }

    private var cancelButton: some View {
        Button {
            onDecision(.cancel)
        } label: {
            Text(configuration.cancelTitle)
                .awFont(AwFont.UI.label)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.aw.accent)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(configuration.cancelAccessibilityLabel ?? configuration.cancelTitle)
        .accessibilityFocused($cancelButtonFocused)
        .focused($cancelButtonKeyFocused)
    }

    private func announceAndFocusCancelButton() {
        guard !didRequestInitialFocus else {
            return
        }
        didRequestInitialFocus = true

        AccessibilityNotification.Announcement(configuration.title).post()
        Task { @MainActor in
            await Task.yield()
            cancelButtonFocused = true
            cancelButtonKeyFocused = true
        }
    }

    private var keyboardHintText: String {
        configuration.keyboardHint
            ?? String(
                localized: "Press ⌘Return to confirm. Return or Esc cancels.",
                comment: "Generic keyboard hint line on an awModal confirmation dialog."
            )
    }

    private var spokenKeyboardHintText: String {
        keyboardHintText.replacingOccurrences(
            of: "⌘Return",
            with: String(
                localized: "Command-Return",
                comment: "Spelled-out form of the Command-Return chord for VoiceOver, substituted into keyboard hint lines."
            ))
    }
}

public extension AwModalView where Content == EmptyView {
    /// Creates a modal view without custom content.
    init(
        configuration: AwModalConfiguration,
        onDecision: @escaping (AwModalDecision) -> Void
    ) {
        self.init(
            configuration: configuration,
            content: { EmptyView() },
            onDecision: onDecision
        )
    }
}
