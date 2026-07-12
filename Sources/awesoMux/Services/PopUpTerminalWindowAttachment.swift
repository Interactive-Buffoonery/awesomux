import AppKit

@MainActor
enum PopUpTerminalWindowAttachment {
    static func attach(_ window: NSWindow?, to parentWindow: NSWindow?) {
        guard let window,
              let parentWindow,
              window.parent !== parentWindow else { return }
        window.parent?.removeChildWindow(window)
        parentWindow.addChildWindow(window, ordered: .above)
    }
}
