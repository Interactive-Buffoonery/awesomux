import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import os
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

@MainActor
func terminalEffectiveTheme(
    for appearance: AppearanceConfig,
    effectiveAppearance: NSAppearance? = NSApp?.effectiveAppearance,
    interfaceStyle: String? = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
) -> TerminalAppearancePreferences.EffectiveTheme {
    switch appearance.theme {
    case .light:
        return .light
    case .dark:
        return .dark
    case .system:
        if let match = effectiveAppearance?.bestMatch(from: [.aqua, .darkAqua]) {
            return (match == .darkAqua) ? .dark : .light
        }

        // `AwesoMuxApp.init` can run before AppKit has assigned `NSApp`.
        // Fall back to the global interface style instead of force-unwrapping
        // the application singleton during startup.
        return (interfaceStyle == "Dark") ? .dark : .light
    }
}

// Internal (not `private`) and `savedFrame`/`save` take an injectable
// `UserDefaults`, defaulted to `.standard`, so characterization tests can drive
// the save/restore round-trip against an isolated suite. Mirrors the seam
// already used by `SettingsDefault.registerInitialValues(_:)`. Runtime call
// sites are unchanged.
enum PrimaryWindowFramePersistence {
    /// SwiftUI scene/window restoration is intentionally not the source of truth
    /// for the primary frame. The app persists under this stable key and feeds
    /// it back through SwiftUI's placement hook so reopen and relaunch share one
    /// frame policy.
    static let frameKey = "awesomux.primaryWindowFrame"

    static func savedFrame(_ defaults: UserDefaults = .standard) -> CGRect? {
        guard let saved = defaults.string(forKey: frameKey) else {
            return nil
        }

        let frame = NSRectFromString(saved)
        guard WindowFrameClampPolicy.isFinite(frame),
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        return frame
    }

    static func save(_ frame: CGRect, to defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: frameKey)
    }

    @MainActor
    static func defaultPlacement() -> WindowPlacement {
        let defaultSize = CGSize(
            width: ContentView.defaultWindowWidth,
            height: ContentView.defaultWindowHeight
        )
        guard let savedFrame = savedFrame() else {
            return WindowPlacement(size: defaultSize)
        }

        // Clamp into the screen the saved frame actually lived on, not the
        // primary — so a docked relaunch returns to its external monitor instead
        // of being dragged onto the laptop, while still rescuing a frame saved on
        // a now-disconnected display. Screen selection is pure + unit-tested in
        // `WindowFrameClampPolicy`. The saved value is `window.frame` in AppKit
        // global coords, the same space `NSScreen.frame` and `WindowPlacement` use.
        let screens = NSScreen.screens.map {
            (frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard let visibleFrame = WindowFrameClampPolicy.restoreVisibleFrame(
            forSavedFrame: savedFrame,
            screens: screens,
            fallbackVisibleFrame: NSScreen.main?.visibleFrame
        ) else {
            return WindowPlacement(savedFrame.origin, size: savedFrame.size)
        }

        let restoredFrame = WindowFrameClampPolicy.clamp(
            savedFrame,
            into: visibleFrame,
            minSize: CGSize(
                width: ContentView.minimumWindowWidth,
                height: ContentView.minimumWindowHeight
            )
        )
        return WindowPlacement(restoredFrame.origin, size: restoredFrame.size)
    }
}

struct PrimaryWindowSurfaceWindow {
    var isMiniaturized: Bool
    var deminiaturize: () -> Void
    var orderFront: () -> Void
}

enum PrimaryWindowSurfacer {
    static func surface(
        window: PrimaryWindowSurfaceWindow?,
        openPrimaryWindow: (() -> Void)?,
        beep: () -> Void
    ) {
        guard let window else {
            guard let openPrimaryWindow else {
                beep()
                return
            }
            openPrimaryWindow()
            return
        }

        if window.isMiniaturized {
            window.deminiaturize()
        }
        window.orderFront()
    }
}

enum AwesoMuxSceneID {
    static let primary = "primary"
    static let settings = "settings"
}
