import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import awesoMux

@Suite("Terminal panel size store")
@MainActor
struct TerminalPanelSizeStoreTests {
    private let minimum = CGSize(width: 360, height: 240)

    @Test("load returns nil before a size is saved for a bucket")
    func loadNilByDefault() throws {
        let store = makeStore(try makeDefaults())
        #expect(store.load(bucket: "1920x1080") == nil)
    }

    @Test("save then load round-trips the size for the same bucket")
    func saveLoadRoundTrip() throws {
        let store = makeStore(try makeDefaults())
        store.save(CGSize(width: 640, height: 420), bucket: "1920x1080")
        #expect(store.load(bucket: "1920x1080") == CGSize(width: 640, height: 420))
    }

    @Test("a size saved on one display does not overwrite another display's size")
    func perDisplayBucketsAreIndependent() throws {
        let store = makeStore(try makeDefaults())
        store.save(CGSize(width: 1200, height: 800), bucket: "3840x2160")
        store.save(CGSize(width: 520, height: 360), bucket: "1440x900")
        #expect(store.load(bucket: "3840x2160") == CGSize(width: 1200, height: 800))
        #expect(store.load(bucket: "1440x900") == CGSize(width: 520, height: 360))
    }

    @Test("sizes below the injected minimum are rejected on save and load")
    func belowMinimumSizesAreRejected() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults)
        // Regression: the corner tab's 260x48 frame once got saved and relaunches reopened collapsed.
        store.save(CGSize(width: 260, height: 48), bucket: "1920x1080")
        #expect(store.load(bucket: "1920x1080") == nil)
    }

    @Test("legacy flat array under the key loads as nil (pre-1.0 format drop)")
    func legacyFlatFormatDropped() throws {
        let defaults = try makeDefaults()
        defaults.set([640.0, 420.0], forKey: "size")
        #expect(makeStore(defaults).load(bucket: "1920x1080") == nil)
    }

    @Test("bucket key is derived from rounded screen dimensions")
    func bucketKeyFromScreenSize() {
        #expect(TerminalPanelSizeStore.bucket(for: CGSize(width: 1920.4, height: 1080.6)) == "1920x1081")
    }

    private func makeStore(_ defaults: UserDefaults) -> TerminalPanelSizeStore {
        TerminalPanelSizeStore(defaults: defaults, key: "size", minimumSize: minimum)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "TerminalPanelSizeStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@Suite("Terminal Companion live-resize capture")
@MainActor
struct PopUpTerminalLiveResizeCaptureTests {
    @Test("programmatic folds cannot replace the user-selected expanded size")
    func programmaticFoldDoesNotCaptureSize() {
        var capture = PopUpTerminalLiveResizeCapture()
        let expandedSize = CGSize(width: 700, height: 500)
        let foldedSize = CGSize(width: 360, height: 240)

        capture.beginProgrammaticMutation()
        capture.start()
        #expect(capture.finish(with: foldedSize) == nil)
        capture.endProgrammaticMutation()

        capture.start()

        #expect(capture.finish(with: expandedSize) == expandedSize)
        #expect(capture.finish(with: foldedSize) == nil)
    }
}
