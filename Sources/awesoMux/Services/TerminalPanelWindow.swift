import AppKit

final class TerminalPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscapeDismiss: (() -> Void)?
    var onPromote: (() -> Void)?

    /// May run mid-sendEvent during pointer re-key. Keep this callback to
    /// flags and tokens; schedule heavier reactions on a later run-loop turn.
    var onKeyStateChanged: ((Bool) -> Void)?

    /// Same constraint as `onKeyStateChanged`: flags and tokens only.
    var onResignKey: (() -> Void)?

    #if DEBUG
    private(set) var isInsidePointerRekey = false
    #endif

    override func becomeKey() {
        super.becomeKey()
        onKeyStateChanged?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyStateChanged?(false)
        onResignKey?()
    }

    override func sendEvent(_ event: NSEvent) {
        // Borderless terminal panels do not become key on pointer input by
        // default. Re-key synchronously so Escape and Cmd-W routing sees the
        // correct window before the pointer event reaches the terminal.
        if !isKeyWindow, FloatingPanelEventPolicy.isReclickActivation(type: event.type) {
            let hasModalSession = NSApp.modalWindow != nil
                || NSApp.windows.contains { $0.attachedSheet != nil }
            if !hasModalSession {
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                #if DEBUG
                isInsidePointerRekey = true
                defer { isInsidePointerRekey = false }
                #endif
                makeKey()
            }
        }

        if let onEscapeDismiss,
           event.type == .keyDown, FloatingPanelEventPolicy.isDismissChord(
            type: event.type,
            keyCode: event.keyCode,
            isARepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ) {
            onEscapeDismiss()
            return
        }

        // Cmd-Return is intercepted by `AwesoMuxApplication` before a
        // window-level command-key event reaches this method.
        super.sendEvent(event)
    }
}
