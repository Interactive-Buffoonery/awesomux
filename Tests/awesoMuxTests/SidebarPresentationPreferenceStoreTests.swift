import Foundation
import Testing
@testable import awesoMux

@Suite("SidebarPresentationPreferenceStore")
struct SidebarPresentationPreferenceStoreTests {
    @Test("missing preference defaults to visible")
    func missingPreferenceDefaultsToVisible() throws {
        let (store, defaults, suiteName) = try makePresentationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!store.isHidden())
    }

    @Test("hidden preference round-trips")
    func hiddenPreferenceRoundTrips() throws {
        let (store, defaults, suiteName) = try makePresentationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.saveHidden(true)
        #expect(store.isHidden())
        store.saveHidden(false)
        #expect(!store.isHidden())
    }

    @Test("saving hidden state uses the app-wide base key")
    func savingHiddenStateUsesAppWideBaseKey() throws {
        let (store, defaults, suiteName) = try makePresentationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.saveHidden(true)

        #expect(defaults.object(forKey: SidebarPresentationPreferenceStore.hiddenKey) != nil)
        #expect(defaults.bool(forKey: SidebarPresentationPreferenceStore.hiddenKey))
    }

    @Test("saving hidden state leaves width preferences unchanged")
    func savingHiddenStateLeavesWidthPreferencesUnchanged() throws {
        let (store, defaults, suiteName) = try makePresentationStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(321.0, forKey: SidebarWidthPreferenceStore.widthKey)
        defaults.set(287.0, forKey: SidebarWidthPreferenceStore.lastNonCollapsedWidthKey)

        store.saveHidden(true)

        #expect(defaults.double(forKey: SidebarWidthPreferenceStore.widthKey) == 321.0)
        #expect(defaults.double(forKey: SidebarWidthPreferenceStore.lastNonCollapsedWidthKey) == 287.0)
    }
}

private func makePresentationStore() throws -> (
    store: SidebarPresentationPreferenceStore,
    defaults: UserDefaults,
    suiteName: String
) {
    let suiteName = "SidebarPresentationPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (SidebarPresentationPreferenceStore(defaults: defaults), defaults, suiteName)
}
