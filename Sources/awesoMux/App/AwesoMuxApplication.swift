import AppKit

@objc(AwesoMuxApplication)
final class AwesoMuxApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }

        ShortcutDiagnostics.logSendEvent(event)

        if SidebarFocusShortcut.matches(event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent matched=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent matched=true action=focusSidebar")
            NotificationCenter.default.post(
                name: .awesoMuxFocusSidebarRequested,
                object: self
            )
            return
        }

        // Holding the chord auto-repeats keyDowns. `matches` already rejected
        // these (it requires `!isARepeat`), so without this branch the repeats
        // would fall through to the focused responder — leaking the ⌃ as a
        // control byte into the PTY. Swallow them on the handleable path.
        if SidebarFocusShortcut.isRepeat(ofFocusSidebarChord: event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent matched=false repeat=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent matched=false repeat=true action=ignore")
            return
        }

        if SidebarVisibilityToggleShortcut.matches(event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent toggleSidebarVisibility=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }
            ShortcutDiagnostics.log("stage=sendEvent toggleSidebarVisibility=true action=toggleSidebarVisibility")
            NotificationCenter.default.post(name: .awesoMuxToggleSidebarVisibilityRequested, object: self)
            return
        }

        if SidebarVisibilityToggleShortcut.isRepeat(ofToggleSidebarVisibilityChord: event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent toggleSidebarVisibility=false repeat=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }
            ShortcutDiagnostics.log("stage=sendEvent toggleSidebarVisibility=false repeat=true action=ignore")
            return
        }

        if SidebarWidthToggleShortcut.matches(event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent toggleSidebarWidth=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent toggleSidebarWidth=true action=toggleSidebarWidth")
            NotificationCenter.default.post(
                name: .awesoMuxToggleSidebarWidthRequested,
                object: self
            )
            return
        }

        if SidebarWidthToggleShortcut.isRepeat(ofToggleSidebarWidthChord: event) {
            guard canHandleSidebarShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent toggleSidebarWidth=false repeat=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent toggleSidebarWidth=false repeat=true action=ignore")
            return
        }

        if CommandPaletteShortcut.matches(event) {
            guard canHandleAppShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent commandPalette=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent commandPalette=true action=toggleCommandPalette")
            NotificationCenter.default.post(
                name: .awesoMuxCommandPaletteRequested,
                object: self
            )
            return
        }

        if CommandPaletteShortcut.isRepeat(ofCommandPaletteChord: event) {
            guard canHandleAppShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent commandPalette=false repeat=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent commandPalette=false repeat=true action=ignore")
            return
        }

        if KeyboardCheatsheetShortcut.matches(event) {
            guard canHandleAppShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent keyboardCheatsheet=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent keyboardCheatsheet=true action=toggleKeyboardCheatsheet")
            NotificationCenter.default.post(
                name: .awesoMuxKeyboardCheatsheetRequested,
                object: self
            )
            return
        }

        if KeyboardCheatsheetShortcut.isRepeat(ofKeyboardCheatsheetChord: event) {
            guard canHandleAppShortcut else {
                ShortcutDiagnostics.log("stage=sendEvent keyboardCheatsheet=false repeat=true blocked=modalOrNoWindow")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent keyboardCheatsheet=false repeat=true action=ignore")
            return
        }

        // Promote the floating panel's slot into the workspace (Cmd-Return).
        // Only fires when the floating panel is key, so Cmd-Return in a normal
        // workspace pane still falls through to the terminal. Handled here
        // rather than in the panel's own `sendEvent` because command-key
        // equivalents are consumed by menu/key-equivalent routing before they
        // reach a window-level override.
        if FloatingPanelEventPolicy.isPromoteChord(
            type: event.type,
            keyCode: event.keyCode,
            isARepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ), let floatingPanel = keyWindow as? TerminalPanelWindow {
            // Panel-scoped rather than the app-wide canHandleAppShortcut the
            // sibling branches use: only a sheet on THIS panel contends for
            // the ⌘Return chord; a sheet on some other window shouldn't
            // disable promote on the key floating panel.
            guard
                FloatingPanelEventPolicy.canPromoteFloatingPanel(
                    hasAttachedSheet: floatingPanel.attachedSheet != nil
                )
            else {
                ShortcutDiagnostics.log("stage=sendEvent promoteFloating=true blocked=attachedSheet")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent promoteFloating=true action=promote")
            floatingPanel.onPromote?()
            return
        }

        super.sendEvent(event)
    }

    private var canHandleAppShortcut: Bool {
        guard isActive, keyWindow != nil || mainWindow != nil else {
            return false
        }

        guard modalWindow == nil else {
            return false
        }

        return !windows.contains { $0.attachedSheet != nil }
    }

    private var canHandleSidebarShortcut: Bool {
        canHandleAppShortcut && awesoMuxPrimaryContentWindow != nil
    }
}
