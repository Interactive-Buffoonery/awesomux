import Foundation

/// Raw values are pinned explicitly (not left to Swift's implicit
/// lowercased-case-name behavior) because they're also the persisted
/// `SettingsKey.updateChannel` plist contract — an accidental case rename
/// must not silently change what's written/read on disk.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable = "stable"
    case beta = "beta"

    var id: Self { self }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }
}
