import Observation

/// One-shot hand-off for "open Settings *on this section*".
///
/// The Settings scene is a singleton whose selection is private view state, so
/// there is no way to target a section through `openWindow(id:)` alone. Reading
/// clears the request: a later re-open with no request must keep whatever
/// section the user last chose rather than snapping back.
@MainActor
@Observable
final class SettingsSectionRequest {
    private(set) var pending: SettingsSectionID?

    func request(_ section: SettingsSectionID) {
        pending = section
    }

    func consume() -> SettingsSectionID? {
        defer { pending = nil }
        return pending
    }
}
