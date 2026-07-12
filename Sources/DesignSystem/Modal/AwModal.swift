import AppKit
import SwiftUI

/// AppKit presenter for an awesoMux modal.
@MainActor
public struct AwModal<Content: View> {
    private let configuration: AwModalConfiguration
    private let anchorWindow: NSWindow?
    private let content: Content

    /// Creates a modal presenter with custom SwiftUI content.
    public init(
        configuration: AwModalConfiguration,
        anchorWindow: NSWindow? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.configuration = configuration
        self.anchorWindow = anchorWindow
        self.content = content()
    }

    /// Presents the modal and returns the user's decision.
    public func run() async -> AwModalDecision {
        await withCheckedContinuation { continuation in
            let presentationAnchor = anchorWindow ?? NSApp.windows.first { window in
                window.isVisible && window.canBecomeMain && window.attachedSheet == nil
            }
            var didResume = false
            var presentedPanel: ModalPanel?

            let complete: (AwModalDecision) -> Void = { decision in
                guard !didResume, let panel = presentedPanel else {
                    return
                }
                didResume = true

                if let presentationAnchor {
                    presentationAnchor.endSheet(panel)
                } else {
                    NSApp.stopModal(withCode: decision.modalResponse)
                }
                panel.orderOut(nil)
                // Break the retain cycle (panel -> hosting controller ->
                // onDecision -> this closure -> presentedPanel box -> panel)
                // so the panel and its SwiftUI tree deallocate after dismissal.
                // Only the box is cleared; dropping contentViewController here
                // would tear down the view whose button action is on the stack.
                presentedPanel = nil
                continuation.resume(returning: decision)
            }

            let rootView = AwModalHostedRoot {
                AwModalView(
                    configuration: configuration,
                    content: { content },
                    onDecision: complete
                )
            }
            let hostingController = NSHostingController(rootView: rootView)
            let panelSize = Self.fittingSize(for: hostingController.view)
            let panel = ModalPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.configure(title: configuration.title)
            panel.onCancel = { complete(.cancel) }
            panel.onConfirm = { complete(.confirm) }
            presentedPanel = panel

            if let presentationAnchor {
                presentationAnchor.beginSheet(panel)
            } else {
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                let response = NSApp.runModal(for: panel)
                guard !didResume else {
                    return
                }
                didResume = true
                panel.orderOut(nil)
                continuation.resume(returning: Self.decision(for: response))
            }
        }
    }

    private static func fittingSize(for view: NSView) -> CGSize {
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        return CGSize(
            width: ceil(max(1, fittingSize.width)),
            height: ceil(max(1, fittingSize.height))
        )
    }

    private static func decision(for response: NSApplication.ModalResponse) -> AwModalDecision {
        response == .OK ? .confirm : .cancel
    }

    private final class ModalPanel: NSPanel {
        var onCancel: (() -> Void)?
        var onConfirm: (() -> Void)?

        override var canBecomeKey: Bool {
            true
        }

        override var canBecomeMain: Bool {
            true
        }

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }

        override func keyDown(with event: NSEvent) {
            if Self.isEscape(event) {
                onCancel?()
                return
            }
            if Self.isKeyboardAccept(event) {
                onConfirm?()
                return
            }

            super.keyDown(with: event)
        }

        override func sendEvent(_ event: NSEvent) {
            if Self.isEscape(event) {
                onCancel?()
                return
            }
            // Intercepted here (like Esc) rather than via a SwiftUI
            // .keyboardShortcut on the confirm button: window-level
            // interception is the one place that provably sees keypad Enter
            // too, keeping AwModal's accept chord identical to the NSAlert
            // dialogs'.
            if Self.isKeyboardAccept(event) {
                onConfirm?()
                return
            }

            super.sendEvent(event)
        }

        func configure(title: String) {
            self.title = title
            setAccessibilityLabel(title)
            backgroundColor = .clear
            isOpaque = false
            hasShadow = false
            isReleasedWhenClosed = false
        }

        private static func isEscape(_ event: NSEvent) -> Bool {
            // Modifiers deliberately ignored: NSAlert cancels on Esc even
            // with Caps Lock or other modifiers engaged, and so do we.
            event.type == .keyDown
                && event.keyCode == 53
                && !event.isARepeat
        }

        private static func isKeyboardAccept(_ event: NSEvent) -> Bool {
            event.type == .keyDown
                && !event.isARepeat
                && AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                )
        }
    }
}

struct AwModalHostedRoot<Content: View>: View {
    private let uiFont: AwUIFontResolver
    private let content: Content

    init(
        uiFont: AwUIFontResolver = AwUIFontRuntime.current,
        @ViewBuilder content: () -> Content
    ) {
        self.uiFont = uiFont
        self.content = content()
    }

    var body: some View {
        content.awUIFont(uiFont)
    }
}

public extension AwModal where Content == EmptyView {
    /// Creates a modal presenter without custom SwiftUI content.
    init(
        configuration: AwModalConfiguration,
        anchorWindow: NSWindow? = nil
    ) {
        self.init(
            configuration: configuration,
            anchorWindow: anchorWindow,
            content: { EmptyView() }
        )
    }
}

private extension AwModalDecision {
    var modalResponse: NSApplication.ModalResponse {
        switch self {
        case .confirm:
            return .OK
        case .cancel:
            return .cancel
        }
    }
}
