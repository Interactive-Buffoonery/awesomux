import AwesoMuxCore
import CoreGraphics
import Foundation

struct SidebarWidthPreferenceStore {
    static let widthKey = "awesomux.sidebar.width"
    static let lastNonCollapsedWidthKey = "awesomux.sidebar.lastNonCollapsedWidth"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func width(windowID: String? = nil) -> CGFloat {
        committedWidth(
            forKey: key(Self.widthKey, windowID: windowID),
            fallback: SidebarWidthPolicy.defaultWidth
        )
    }

    func lastNonCollapsedWidth(windowID: String? = nil) -> CGFloat {
        let raw = persistedDouble(forKey: key(Self.lastNonCollapsedWidthKey, windowID: windowID))
        return SidebarWidthPolicy.normalizedLastNonCollapsedWidth(raw.map { CGFloat($0) })
    }

    func saveWidth(_ width: CGFloat, windowID: String? = nil) {
        // Free-drag: persist the exact dragged width (floor-clamped only), not a
        // snapped canonical (INT-535). The dynamic max is enforced live by the
        // split delegate; on restore a too-wide value is re-clamped against the
        // window there.
        let committed = SidebarWidthPolicy.committedWidth(for: width)
        defaults.set(Double(committed), forKey: key(Self.widthKey, windowID: windowID))
        if SidebarWidthPolicy.mode(for: committed) != .collapsed {
            saveLastNonCollapsedWidth(committed, windowID: windowID)
        }
    }

    func saveLastNonCollapsedWidth(_ width: CGFloat, windowID: String? = nil) {
        let normalized = SidebarWidthPolicy.normalizedLastNonCollapsedWidth(width)
        defaults.set(
            Double(normalized),
            forKey: key(Self.lastNonCollapsedWidthKey, windowID: windowID)
        )
    }

    private func committedWidth(forKey key: String, fallback: CGFloat) -> CGFloat {
        guard let raw = persistedDouble(forKey: key) else {
            return fallback
        }
        return SidebarWidthPolicy.committedWidth(for: CGFloat(raw))
    }

    private func persistedDouble(forKey key: String) -> Double? {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return nil
        }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    private func key(_ base: String, windowID: String?) -> String {
        guard let windowID,
              !windowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return "\(base).\(windowID)"
    }
}
