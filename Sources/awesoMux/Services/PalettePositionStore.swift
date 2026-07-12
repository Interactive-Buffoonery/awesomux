import CoreGraphics
import Foundation

/// Persists the command palette's user-dragged origin across launches.
///
/// NSWindow's `setFrameAutosaveName` silently no-ops for windows hosted in a
/// SwiftUI scene, so the palette panel can't rely on AppKit's named-frame
/// machinery — we store the origin in plain `UserDefaults` ourselves. In-session
/// position is preserved by keeping the panel instance alive; this store only
/// covers the cross-launch case (and feeds the "first open is centered, then
/// remembered" behavior).
struct PalettePositionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "com.awesomux.commandPalette.origin"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// The remembered origin, or `nil` when the palette has never been moved
    /// (so the caller centers it).
    func load() -> CGPoint? {
        guard let stored = defaults.array(forKey: key) as? [Double],
              stored.count == 2 else {
            return nil
        }
        return CGPoint(x: stored[0], y: stored[1])
    }

    func save(_ origin: CGPoint) {
        defaults.set([Double(origin.x), Double(origin.y)], forKey: key)
    }

    /// Forget the remembered origin so the next open re-centers (the
    /// "Reset Palette Position" command).
    func clear() {
        defaults.removeObject(forKey: key)
    }
}
