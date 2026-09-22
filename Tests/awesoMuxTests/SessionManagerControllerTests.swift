import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing

@testable import awesoMux

@Suite("Session Manager controller")
@MainActor
struct SessionManagerControllerTests {
    @Test("one failed pane cancels confirmation waits for its siblings")
    func failedPaneCancelsSiblingConfirmation() async {
        let center = SessionRecoveryConfirmationCenter()
        let failed = TerminalSessionID.generate()
        let pending = TerminalSessionID.generate()
        center.begin(pending, daemonPID: 42, createdEpoch: 100)
        var result: Bool?
        let task = Task {
            result = await SessionManagerModel.waitForConfirmations(
                for: [failed, pending], center: center)
        }
        let completed = await waitUntilEventually(deadline: .seconds(10)) { result != nil }
        task.cancel()
        await task.value

        #expect(completed)
        #expect(result == false)
        #expect(center.expectationToken(for: pending) == nil)
    }

    @Test("multi-pane restore requires every daemon to be detached")
    func multiPaneRestoreRequiresEveryDaemon() {
        let first = TerminalSessionID.generate()
        let second = TerminalSessionID.generate()
        let detached = LiveDaemon(
            id: first, pid: 10, createdEpoch: 20, clients: 0, daemonPID: 30)
        let attached = LiveDaemon(
            id: second, pid: 11, createdEpoch: 21, clients: 1, daemonPID: 31)

        #expect(
            SessionManagerModel.restorableDaemons(
                for: [first, second], in: [detached, attached]) == nil)
        #expect(
            SessionManagerModel.restorableDaemons(for: [first, second], in: [detached]) == nil)
        #expect(
            SessionManagerModel.restorableDaemons(
                for: [first, second],
                in: [
                    detached,
                    LiveDaemon(
                        id: second, pid: 11, createdEpoch: 21, clients: 0, daemonPID: 31
                    ),
                ]
            )?.count == 2)
    }

    @Test("Configuring auto-cleanup dismisses before opening Settings")
    func configureAutoCleanupDismissesBeforeCallback() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "session-manager-controller")
        let controller = SessionManagerController(presentPanel: { _ in })
        let model = SessionManagerModel(
            store: SessionStore(),
            settings: AppSettingsStore(
                fileStore: ConfigFileStore(
                    configURL: temporaryDirectory.url.appending(path: "config.toml")
                ),
                legacySnapshotProvider: { nil }
            ),
            policy: DaemonPolicyStore(
                fileURL: temporaryDirectory.url.appending(path: "daemon-pins.json")
            )
        )
        controller.show(model: model, relativeTo: nil, onSelect: { _, _ in })
        defer {
            controller.onConfigureAutoCleanup = {}
            controller.dismiss()
        }
        #expect(controller.isVisible)

        var callbackCount = 0
        var panelWasVisibleWhenCallbackRan = true
        controller.onConfigureAutoCleanup = { [weak controller] in
            callbackCount += 1
            panelWasVisibleWhenCallbackRan = controller?.isVisible ?? true
        }

        controller.configureAutoCleanup()

        #expect(callbackCount == 1)
        #expect(panelWasVisibleWhenCallbackRan == false)
        #expect(controller.isVisible == false)
    }
}
