import Foundation

struct SidebarPresentationPreferenceStore {
    static let hiddenKey = "awesomux.sidebar.hidden"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isHidden(windowID: String? = nil) -> Bool {
        defaults.bool(forKey: key(Self.hiddenKey, windowID: windowID))
    }

    func saveHidden(_ isHidden: Bool, windowID: String? = nil) {
        defaults.set(isHidden, forKey: key(Self.hiddenKey, windowID: windowID))
    }

    private func key(_ base: String, windowID: String?) -> String {
        guard let windowID,
            !windowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return base
        }
        return "\(base).\(windowID)"
    }
}
