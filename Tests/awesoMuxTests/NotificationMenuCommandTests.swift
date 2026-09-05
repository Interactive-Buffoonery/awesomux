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
}
