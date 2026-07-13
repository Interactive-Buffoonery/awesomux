import Foundation

struct SidebarPresentationPreferenceStore {
    static let hiddenKey = "awesomux.sidebar.hidden"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isHidden() -> Bool {
        defaults.bool(forKey: Self.hiddenKey)
    }

    func saveHidden(_ isHidden: Bool) {
        defaults.set(isHidden, forKey: Self.hiddenKey)
    }
}
