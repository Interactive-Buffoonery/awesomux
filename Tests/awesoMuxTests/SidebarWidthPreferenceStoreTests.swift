import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite("SidebarWidthPreferenceStore")
struct SidebarWidthPreferenceStoreTests {
    @Test("missing values fall back to expanded width")
    func missingValuesFallbackToExpanded() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(store.width() == SidebarWidthPolicy.expandedWidth)
        #expect(store.lastNonCollapsedWidth() == SidebarWidthPolicy.expandedWidth)
    }

    @Test("persisted widths are restored exactly, not snapped (INT-535)")
    func persistedWidthsAreExact() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Above the rail threshold the exact dragged width is preserved (not snapped
        // to a canonical). (Widths in the rail zone settle to collapsed — tested in
        // the policy suite.)
        let w1 = SidebarWidthPolicy.railThreshold + 37
        defaults.set(Double(w1), forKey: SidebarWidthPreferenceStore.widthKey)
        #expect(store.width() == w1)

        let w2 = SidebarWidthPolicy.railThreshold + 110
        defaults.set(Double(w2), forKey: SidebarWidthPreferenceStore.widthKey)
        #expect(store.width() == w2)
    }

    @Test("save/restore round-trips an arbitrary free width")
    func roundTripsArbitraryWidth() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let w = SidebarWidthPolicy.railThreshold + 50
        store.saveWidth(w)
        #expect(store.width() == w)
        #expect(store.lastNonCollapsedWidth() == w)
    }

    @Test("restore clamps a below-floor persisted width up to the collapsed floor")
    func restoreClampsToFloor() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(10, forKey: SidebarWidthPreferenceStore.widthKey)
        #expect(store.width() == SidebarWidthPolicy.collapsedWidth)
    }

    @Test("collapsed last non-collapsed persistence falls back to expanded")
    func collapsedLastNonCollapsedFallsBack() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            Double(SidebarWidthPolicy.collapsedWidth),
            forKey: SidebarWidthPreferenceStore.lastNonCollapsedWidthKey
        )

        #expect(store.lastNonCollapsedWidth() == SidebarWidthPolicy.expandedWidth)
    }

    @Test("saving width also records last non-collapsed width when applicable")
    func savingWidthRecordsRestoreWidth() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let free = SidebarWidthPolicy.railThreshold + 40
        store.saveWidth(free)
        store.saveWidth(SidebarWidthPolicy.collapsedWidth)

        #expect(store.width() == SidebarWidthPolicy.collapsedWidth)
        // Restore width preserves the exact free width, not a snapped canonical.
        #expect(store.lastNonCollapsedWidth() == free)
    }

    @Test("window IDs use per-window keys without changing the base fallback")
    func windowIDsUseScopedKeys() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let w = SidebarWidthPolicy.railThreshold + 30
        store.saveWidth(w, windowID: "primary")

        #expect(defaults.object(forKey: "\(SidebarWidthPreferenceStore.widthKey).primary") != nil)
        #expect(store.width(windowID: "primary") == w)
        #expect(store.width() == SidebarWidthPolicy.expandedWidth)
    }
}

private func makeStore() throws -> (
    store: SidebarWidthPreferenceStore,
    defaults: UserDefaults,
    suiteName: String
) {
    let suiteName = "SidebarWidthPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (SidebarWidthPreferenceStore(defaults: defaults), defaults, suiteName)
}
