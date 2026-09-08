import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing

@testable import awesoMux

@Suite("Session Manager controller")
@MainActor
struct SessionManagerControllerTests {
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
        controller.show(model: model, relativeTo: nil, onJump: { _ in })
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
