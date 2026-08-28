import AppKit
import SwiftUI

struct SidebarNewWorkspaceFocusTarget: NSViewRepresentable {
    let focusRequestID: Int
    let focusIsActive: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> SidebarNewWorkspaceFocusButton {
        let button = SidebarNewWorkspaceFocusButton()
        update(button)
        return button
    }

    func updateNSView(_ nsView: SidebarNewWorkspaceFocusButton, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: SidebarNewWorkspaceFocusButton, coordinator: Void) {
        nsView.dismantle()
    }

    private func update(_ button: SidebarNewWorkspaceFocusButton) {
        button.update(
            focusRequestID: focusRequestID,
            focusIsActive: focusIsActive,
            onActivate: onActivate
        )
    }
}

@MainActor
final class SidebarNewWorkspaceFocusButton: NSButton {
    static let targetIdentifier =
        "com.interactivebuffoonery.awesomux.sidebar.newWorkspace"

    var onActivate: (() -> Void)?

    private var requestedFocusID = 0
    private var fulfilledFocusID = 0
    private var accessibilityFocused = false
    private var isRetired = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isTransparent = true
        refusesFirstResponder = false
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            String(localized: "New Workspace", comment: "Sidebar action to create a workspace."))
        setAccessibilityHelp(
            String(
                localized: "Creates a new workspace in the current group.",
                comment: "Accessibility help for the sidebar New Workspace action."
            ))
        setAccessibilityIdentifier(Self.targetIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            accessibilityFocused = false
        }
        scheduleFocusIfNeeded()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            setAccessibilityFocused(false)
        }
        return resigned
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        self.accessibilityFocused = accessibilityFocused && !isRetired
        if self.accessibilityFocused {
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    override func isAccessibilityFocused() -> Bool {
        accessibilityFocused
    }

    override func accessibilityPerformPress() -> Bool {
        performActivation()
    }

    func update(
        focusRequestID: Int,
        focusIsActive: Bool,
        onActivate: @escaping () -> Void
    ) {
        guard !isRetired else { return }
        self.onActivate = onActivate
        requestedFocusID = focusIsActive ? focusRequestID : 0
        if !focusIsActive {
            if let window, window.firstResponder === self {
                _ = window.makeFirstResponder(window)
            }
            setAccessibilityFocused(false)
        }
        scheduleFocusIfNeeded()
    }

    func dismantle() {
        if let window, window.firstResponder === self {
            _ = window.makeFirstResponder(window)
        }
        isRetired = true
        requestedFocusID = 0
        onActivate = nil
        setAccessibilityFocused(false)
    }

    @objc private func activate() {
        _ = performActivation()
    }

    @discardableResult
    private func performActivation() -> Bool {
        guard !isRetired, let onActivate else { return false }
        if let window, window.firstResponder === self {
            _ = window.makeFirstResponder(window)
        }
        setAccessibilityFocused(false)
        onActivate()
        return true
    }

    private func scheduleFocusIfNeeded() {
        let requestID = requestedFocusID
        guard requestID > 0, requestID != fulfilledFocusID, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRetired, self.requestedFocusID == requestID,
                self.fulfilledFocusID != requestID, let window = self.window
            else {
                return
            }
            guard window.makeFirstResponder(self) else { return }
            self.fulfilledFocusID = requestID
            self.setAccessibilityFocused(true)
        }
    }
}
