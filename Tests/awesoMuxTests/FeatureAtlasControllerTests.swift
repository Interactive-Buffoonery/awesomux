import Foundation
import Testing

@testable import awesoMux

@Suite("Feature Atlas controller")
@MainActor
struct FeatureAtlasControllerTests {
    @Test("Agent guidance is included by default and can be restored")
    func guidancePreferenceIsReversible() {
        let defaults = isolatedDefaults("atlas.ctrl.preference")
        let controller = FeatureAtlasController(defaults: defaults)

        #expect(controller.visibleCardIDs == FeatureAtlasCardID.allCases)

        controller.setShowsAgentFeatures(false)
        #expect(controller.visibleCardIDs.contains(.agentStatus) == false)
        #expect(defaults.bool(forKey: SettingsKey.featureAtlasShowsAgentFeatures) == false)

        controller.setShowsAgentFeatures(true)
        #expect(controller.visibleCardIDs == FeatureAtlasCardID.allCases)
        #expect(defaults.bool(forKey: SettingsKey.featureAtlasShowsAgentFeatures) == true)
    }

    @Test("A saved terminal-only preference survives controller recreation")
    func terminalOnlyPreferencePersists() {
        let defaults = isolatedDefaults("atlas.ctrl.persist")
        defaults.set(false, forKey: SettingsKey.featureAtlasShowsAgentFeatures)

        let controller = FeatureAtlasController(defaults: defaults)

        #expect(controller.showsAgentFeatures == false)
        #expect(controller.visibleCardIDs == FeatureAtlasCardID.allCases.filter { $0 != .agentStatus })
    }

    @Test("Repeated recall is observable without resetting the preference")
    func repeatedRecallPreservesPreference() {
        let controller = FeatureAtlasController(defaults: isolatedDefaults("atlas.ctrl.recall"))
        controller.setShowsAgentFeatures(false)

        controller.showForTesting()
        let firstToken = controller.presentationToken
        controller.showForTesting()

        #expect(controller.isVisible == true)
        #expect(controller.presentationToken != firstToken)
        #expect(controller.showsAgentFeatures == false)
    }

    @Test("Unavailable cards stay open and do not run")
    func unavailableRouteStaysVisible() {
        let controller = FeatureAtlasController(defaults: isolatedDefaults("atlas.ctrl.unavailable"))
        var runCount = 0
        controller.configure(routes: [
            .markdown: FeatureAtlasRoute(
                isAvailable: { false },
                unavailableReason: { "Close the current sheet." },
                run: { runCount += 1 })
        ])
        controller.showForTesting()

        controller.activate(.markdown)

        #expect(controller.isVisible == true)
        #expect(runCount == 0)
        #expect(controller.unavailableReason(.markdown) == "Close the current sheet.")
    }

    @Test("Available cards dismiss the atlas before routing")
    func availableRouteDismissesThenRuns() {
        let controller = FeatureAtlasController(defaults: isolatedDefaults("atlas.ctrl.available"))
        var wasVisibleWhenRun: Bool?
        controller.configure(routes: [
            .commandPalette: FeatureAtlasRoute {
                wasVisibleWhenRun = controller.isVisible
            }
        ])
        controller.showForTesting()

        #expect(controller.unavailableReason(.commandPalette) == nil)

        controller.activate(.commandPalette)

        #expect(controller.isVisible == false)
        #expect(wasVisibleWhenRun == false)
    }

    @Test("Cmd-W only closes the key atlas window")
    func closeRoutingRequiresKeyWindow() {
        let controller = FeatureAtlasController(defaults: isolatedDefaults("atlas.ctrl.close"))
        controller.showForTesting()

        controller.handleKeyStateChangedForTesting(false)
        #expect(controller.hideIfKeyWindow() == false)
        #expect(controller.isVisible == true)

        controller.handleKeyStateChangedForTesting(true)
        #expect(controller.hideIfKeyWindow() == true)
        #expect(controller.isVisible == false)
    }

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
