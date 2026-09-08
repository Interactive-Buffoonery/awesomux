import AwesoMuxTestSupport
import Foundation
import Testing

@Suite("Notification menu commands")
struct NotificationMenuCommandTests {
    // Commands cannot be hosted by the existing test harness. Pin the menu
    // wiring here; PaletteCommandRegistryTests covers the underlying state.
    @Test("Notification menu actions retain their state conditions and gate on sheets")
    func notificationActionsGateOnSheets() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/App/AwesoMuxApp.swift")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        #expect(
            source.contains(
                """
                Button("Acknowledge Workspace") {
                    if let id = sessionStore.selectedSessionID {
                        sessionStore.acknowledgeAllPanes(in: id)
                    }
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.acknowledgeWorkspace))
                .disabled(!selectedSessionNeedsAcknowledgement || isAnySheetPresented)
                """.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            )
        )
        #expect(
            source.contains(
                """
                Button("Clear All Notifications") {
                sessionStore.acknowledgeAllSessions()
                }
                .disabled(sessionStore.unreadNotificationTotal == 0 || isAnySheetPresented)
                """
            )
        )
    }

    @Test("Keyboard Shortcuts uses a native Help-menu shortcut")
    func keyboardShortcutsUsesNativeHelpMenuShortcut() throws {
        let source = try SourceContract.source(at: "Sources/awesoMux/App/AwesoMuxApp.swift")
        let helpMenu = try SourceContract.declarationBody(
            after: "CommandGroup(replacing: .help) {",
            in: source,
            path: "Sources/awesoMux/App/AwesoMuxApp.swift"
        )

        #expect(helpMenu.contains("Button(\"Keyboard Shortcuts\")"))
        #expect(helpMenu.contains("NSApp.currentEvent?.type == .keyDown"))
        #expect(helpMenu.contains("NSApp.currentEvent?.isARepeat == true"))
        #expect(helpMenu.contains("toggleKeyboardCheatsheet()"))
        #expect(helpMenu.contains(".keyboardShortcut(shortcut(KeyboardShortcutCatalog.showKeyboardCheatsheet))"))
        #expect(helpMenu.contains(".disabled(isAnySheetPresented)"))
        #expect(!source.contains("keyboardCheatsheetMenuTitle"))

        let application = try SourceContract.source(at: "Sources/awesoMux/App/AwesoMuxApplication.swift")
        #expect(!application.contains("KeyboardCheatsheetShortcut.matches(event)"))
        #expect(!application.contains("KeyboardCheatsheetShortcut.isRepeat(ofKeyboardCheatsheetChord: event)"))
    }
}
