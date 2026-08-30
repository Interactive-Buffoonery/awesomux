import AppKit
import AwesoMuxConfig
import Observation
import SwiftUI

enum FeatureAtlasCardID: String, CaseIterable, Identifiable {
    case commandPalette
    case worktrees
    case agentStatus
    case remoteWorkspaces
    case markdown
    case updates

    var id: Self { self }
}

struct FeatureAtlasRoute {
    let isAvailable: @MainActor () -> Bool
    let unavailableReason: @MainActor () -> String?
    let run: @MainActor () -> Void

    init(
        isAvailable: @escaping @MainActor () -> Bool = { true },
        unavailableReason: @escaping @MainActor () -> String? = { nil },
        run: @escaping @MainActor () -> Void
    ) {
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.run = run
    }
}

/// Presents the optional D.A.V.E. feature atlas. Unlike the welcome tour this
/// controller has no automatic presentation policy: every `show()` call comes
/// from an explicit user action.
@MainActor
@Observable
final class FeatureAtlasController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isKeyWindow = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var routes: [FeatureAtlasCardID: FeatureAtlasRoute] = [:]
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false
    private(set) var presentationToken = 0
    private(set) var showsAgentFeatures: Bool

    private static let panelSize = CGSize(width: 780, height: 650)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsAgentFeatures =
            defaults.object(forKey: SettingsKey.featureAtlasShowsAgentFeatures) as? Bool
            ?? true
    }

    func configure(routes: [FeatureAtlasCardID: FeatureAtlasRoute]) {
        self.routes = routes
    }

    /// Repeated recall fronts the one retained panel and preserves the current
    /// guidance preference. It never creates a second atlas window.
    func show() {
        beginPresentation()
        let isNewPanel = panel == nil
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.hostSwiftUIContent(makeRootView())
        if isNewPanel {
            panel.setFixedContentSize(Self.panelSize)
            panel.center()
        }
        panel.presentAndFocus()
        AccessibilityNotification.Announcement(
            String(
                localized: "Discover awesoMux",
                comment: "Announced to VoiceOver when the D.A.V.E. feature atlas opens")
        ).post()
    }

    func dismiss() {
        isVisible = false
        isKeyWindow = false
        panel?.orderOut(nil)
    }

    func hideIfKeyWindow() -> Bool {
        guard isVisible, isKeyWindow else { return false }
        dismiss()
        return true
    }

    func setShowsAgentFeatures(_ showsAgentFeatures: Bool) {
        guard self.showsAgentFeatures != showsAgentFeatures else { return }
        self.showsAgentFeatures = showsAgentFeatures
        defaults.set(showsAgentFeatures, forKey: SettingsKey.featureAtlasShowsAgentFeatures)
    }

    var visibleCardIDs: [FeatureAtlasCardID] {
        FeatureAtlasCardID.allCases.filter { showsAgentFeatures || $0 != .agentStatus }
    }

    func isAvailable(_ id: FeatureAtlasCardID) -> Bool {
        routes[id]?.isAvailable() == true
    }

    func unavailableReason(_ id: FeatureAtlasCardID) -> String? {
        guard !isAvailable(id) else { return nil }
        return routes[id]?.unavailableReason()
    }

    /// Availability is checked at activation time, before the atlas is hidden.
    /// A stale card therefore announces why it cannot run instead of closing
    /// the atlas and silently dropping the user's action.
    func activate(_ id: FeatureAtlasCardID) {
        guard let route = routes[id], route.isAvailable() else {
            let reason =
                routes[id]?.unavailableReason()
                ?? String(
                    localized: "That feature isn't available right now.",
                    comment: "Fallback announcement when a Feature Atlas action cannot run")
            AccessibilityNotification.Announcement(reason).post()
            return
        }
        dismiss()
        route.run()
    }

    private func beginPresentation() {
        presentationToken += 1
        isVisible = true
    }

    @ViewBuilder
    private func makeRootView() -> some View {
        let root = FeatureAtlasView(
            controller: self,
            presentationToken: presentationToken
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func makePanel() -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            backing: .buffered,
            defer: false
        )
        panel.title = "Discover awesoMux"
        panel.setAccessibilityLabel("Discover awesoMux")
        panel.showsStandardWindowButtons = true
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onKeyStateChanged = { [weak self] isKey in
            self?.isKeyWindow = isKey
        }
        panel.handlesKeyEvent = { [weak self] event in
            if FloatingPanelEventPolicy.isDismissChord(
                type: event.type,
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                modifiers: event.modifierFlags
            ) || FloatingPanelEventPolicy.isCloseChord(event) {
                self?.dismiss()
                return true
            }
            return false
        }
        return panel
    }

    // MARK: - Test seams

    func showForTesting() {
        beginPresentation()
    }

    func handleKeyStateChangedForTesting(_ isKey: Bool) {
        isKeyWindow = isKey
    }
}
