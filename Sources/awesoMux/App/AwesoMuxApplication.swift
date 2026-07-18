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

        // Promote a terminal panel into the workspace (Cmd-Return). Routing
        // from the event's window keeps child-window Companion events attached
        // to their source even when AppKit reports the primary window as key.
        // Cmd-Return in a normal workspace pane still falls through to the
        // terminal. Intercept here rather than in the panel's own `sendEvent`
        // because menu/key-equivalent routing consumes command-key equivalents
        // before they reach a window-level override.
        if FloatingPanelEventPolicy.isPromoteChord(
            type: event.type,
            keyCode: event.keyCode,
            isARepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ), let terminalPanel = Self.promotionTarget(for: event) {
            // Scope sheet checks to the terminal panel and its Companion
            // parent. A sheet on an unrelated window does not own this chord,
            // while an app-modal session always does.
            guard
                FloatingPanelEventPolicy.canPromoteTerminalPanel(
                    hasAttachedSheet: terminalPanel.attachedSheet != nil,
                    parentHasAttachedSheet: terminalPanel.parent?.attachedSheet != nil,
                    hasModalSession: modalWindow != nil
                )
            else {
                ShortcutDiagnostics.log("stage=sendEvent promoteFloating=true blocked=modalInputOwner")
                super.sendEvent(event)
                return
            }

            ShortcutDiagnostics.log("stage=sendEvent promoteFloating=true action=promote")
            terminalPanel.onPromote?()
            return
        }

        super.sendEvent(event)
    }

    static func promotionTarget(for event: NSEvent) -> TerminalPanelWindow? {
        event.window as? TerminalPanelWindow
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
