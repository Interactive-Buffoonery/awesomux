import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Floating panel dismiss confirmation (controller)")
@MainActor
struct FloatingPanelDismissConfirmationControllerTests {
    @Test("toggle after first Escape hides risky slot without teardown")
    func toggleAfterFirstEscapeHidesRiskySlotWithoutTeardown() {
        let workspace = TerminalSession(
            title: "main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        let riskyFloatingStore = Self.riskyFloatingStore()
        let controller = TerminalPanelController(mode: .floating)
        controller.seedDismissConfirmationTestSlot(
            workspaceID: workspace.id,
            store: riskyFloatingStore
        )

        controller.dismiss(source: .escape)

        #expect(controller.isVisible)
        #expect(controller.isDismissConfirmationPendingForTesting)
        #expect(controller.hasFloatingSlotForTesting(workspaceID: workspace.id))

        controller.dismiss(source: .toggle)

        #expect(!controller.isVisible)
        #expect(!controller.isDismissConfirmationPendingForTesting)
        #expect(controller.hasFloatingSlotForTesting(workspaceID: workspace.id))
    }

    @Test("second Escape tears down risky slot")
    func secondEscapeTearsDownRiskySlot() {
        let workspace = TerminalSession(
            title: "main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        let controller = TerminalPanelController(mode: .floating)
        controller.seedDismissConfirmationTestSlot(
            workspaceID: workspace.id,
            store: Self.riskyFloatingStore()
        )

        controller.dismiss(source: .escape)
        controller.dismiss(source: .escape)

        #expect(!controller.isVisible)
        #expect(!controller.isDismissConfirmationPendingForTesting)
        #expect(!controller.hasFloatingSlotForTesting(workspaceID: workspace.id))
    }

    @Test("bridged away-from-prompt slot requires dismiss confirmation")
    func bridgedAwayFromPromptSlotRequiresConfirmation() {
        // Quit-safe (daemon survives a quit) but close-risky (dismiss discards
        // the surfaces and kills the daemon). The dismiss gate is close-scoped,
        // so the first Escape must confirm rather than silently tear down.
        let workspace = TerminalSession(
            title: "main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        let controller = TerminalPanelController(mode: .floating)
        controller.seedDismissConfirmationTestSlot(
            workspaceID: workspace.id,
            store: Self.bridgedAwayFromPromptFloatingStore()
        )

        controller.dismiss(source: .escape)

        #expect(controller.isVisible)
        #expect(controller.isDismissConfirmationPendingForTesting)
        #expect(controller.hasFloatingSlotForTesting(workspaceID: workspace.id))
    }

    @Test("first Escape tears down clean slot")
    func firstEscapeTearsDownCleanSlot() {
        let workspace = TerminalSession(
            title: "main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        let controller = TerminalPanelController(mode: .floating)
        controller.seedDismissConfirmationTestSlot(
            workspaceID: workspace.id,
            store: Self.cleanFloatingStore()
        )

        controller.dismiss(source: .escape)

        #expect(!controller.isVisible)
        #expect(!controller.hasFloatingSlotForTesting(workspaceID: workspace.id))
    }

    private static func riskyFloatingStore() -> SessionStore {
        let session = TerminalSession(
            title: "vim",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle,
            needsTerminalQuitConfirmation: true
        )
        return SessionStore(groups: [
            SessionGroup(name: "Floating Panel", sessions: [session])
        ])
    }

    private static func bridgedAwayFromPromptFloatingStore() -> SessionStore {
        var pane = TerminalPane(
            title: "vim",
            workingDirectory: "/tmp",
            agentKind: .shell
        )
        pane.foregroundProcessLiveness = .bridged
        pane.needsTerminalQuitConfirmation = true
        let session = TerminalSession(
            title: "vim",
            workingDirectory: "/tmp",
            layout: .pane(pane)
        )
        return SessionStore(groups: [
            SessionGroup(name: "Floating Panel", sessions: [session])
        ])
    }

    private static func cleanFloatingStore() -> SessionStore {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        return SessionStore(groups: [
            SessionGroup(name: "Floating Panel", sessions: [session])
        ])
    }
}
