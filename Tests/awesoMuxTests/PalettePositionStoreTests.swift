import CoreGraphics
import Foundation
import Testing
@testable import awesoMux

@Suite("Palette position store")
struct PalettePositionStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "PalettePositionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("load returns nil before anything is saved")
    func loadNilByDefault() throws {
        let store = PalettePositionStore(defaults: try makeDefaults(), key: "origin")
        #expect(store.load() == nil)
    }

    @Test("save then load round-trips the origin")
    func saveLoadRoundTrip() throws {
        let store = PalettePositionStore(defaults: try makeDefaults(), key: "origin")
        store.save(CGPoint(x: 120, y: 340))

        let loaded = store.load()
        #expect(loaded?.x == 120)
        #expect(loaded?.y == 340)
    }

    @Test("clear forgets a saved origin so the next open re-centers")
    func clearResetsOrigin() throws {
        let store = PalettePositionStore(defaults: try makeDefaults(), key: "origin")
        store.save(CGPoint(x: 10, y: 20))
        store.clear()

        #expect(store.load() == nil)
    }

    @Test("malformed stored value is ignored")
    func malformedValueIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set([42.0], forKey: "origin") // wrong arity
        let store = PalettePositionStore(defaults: defaults, key: "origin")

        #expect(store.load() == nil)
    }
}
