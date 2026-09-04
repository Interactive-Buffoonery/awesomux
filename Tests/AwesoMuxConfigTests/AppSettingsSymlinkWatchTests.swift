import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import AwesoMuxConfig

@MainActor
@Suite("Symlinked settings observation")
struct AppSettingsSymlinkWatchTests {
    @Test("Target edits reload and survive a later UI save", arguments: [false, true], [false, true])
    func targetEdits(atomic: Bool, relative: Bool) async throws {
        let fixture = try Fixture(relativeLink: relative)
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.bootstrap()
        store.startWatching()
        defer { store.stopWatching() }

        for group in ["External one", "External two"] {
            try fixture.write(group, to: fixture.target, atomic: atomic)
            #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == group })
        }
        store.notifications.update { $0.muted = true }
        let saved = try TOMLConfigCodec().decode(Data(contentsOf: fixture.target))
        #expect(saved.workspaces.defaultGroup == "External two")
        #expect(saved.notifications.muted)
        #expect(saved.unknownTopLevelTables["custom"] != nil)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.config.path)
                == (relative ? "../dotfiles/config.toml" : fixture.target.path))
        // The app's save replaces the target inode too.
        try fixture.write("After UI save", to: fixture.target, atomic: false)
        #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == "After UI save" })
    }

    @Test("Retargeting follows the new config and ignores old target content")
    func retarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.bootstrap()
        store.startWatching()
        defer { store.stopWatching() }
        let newTarget = fixture.root.appendingPathComponent("other/config.toml")
        try fixture.write("New target", to: newTarget)
        let replacement = fixture.config.deletingLastPathComponent().appendingPathComponent("replacement")
        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: newTarget)
        #expect(rename(replacement.path, fixture.config.path) == 0)
        #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == "New target" })
        try fixture.write("Old target", to: fixture.target)
        #expect(
            !(await waitUntilEventually(deadline: .milliseconds(200)) {
                store.workspaces.value.defaultGroup != "New target"
            }))
        try fixture.write("Still new", to: newTarget, atomic: false)
        #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == "Still new" })
        #expect(store.config.workspaces.defaultGroup != "Old target")
    }

    @Test("Invalid target content keeps safe settings and recovers")
    func invalidTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.bootstrap()
        store.startWatching()
        defer { store.stopWatching() }
        try "[appearance]\ntheme =".write(to: fixture.target, atomically: true, encoding: .utf8)
        #expect(await waitUntilEventually { store.isDiskConfigInvalid })
        #expect(store.workspaces.value.defaultGroup == "Initial")
        store.notifications.update { $0.muted = true }
        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == "[appearance]\ntheme =")
        try fixture.write("Recovered", to: fixture.target)
        #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == "Recovered" })
        #expect(!store.isDiskConfigInvalid)
    }

    @Test("Deleting a target resets defaults and keeps the link watchable", arguments: [false, true])
    func deletion(removeDirectory: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.bootstrap()
        store.startWatching()
        defer { store.stopWatching() }
        try FileManager.default.removeItem(at: removeDirectory ? fixture.target.deletingLastPathComponent() : fixture.target)
        #expect(await waitUntilEventually { store.config == .defaultValue })
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.config.path) == fixture.target.path)
        try fixture.write("Recreated", to: fixture.target, atomic: false)
        #expect(await waitUntilEventually { store.workspaces.value.defaultGroup == "Recreated" })
    }

    @Test("The app's own saves settle without a reload loop")
    func ownSaveSettles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var reloads = 0
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: fixture.config),
            watchDebounceNanoseconds: 20_000_000,
            diagnosticEventHandler: { _ in reloads += 1 },
            legacySnapshotProvider: { nil }
        )
        store.bootstrap()
        store.startWatching()
        defer { store.stopWatching() }
        store.notifications.update { $0.muted = true }
        #expect(await waitUntilEventually { reloads > 0 })
        #expect(!(await waitUntilEventually(deadline: .milliseconds(300)) { reloads > 5 }))
        #expect(store.notifications.value.muted)
        #expect(!store.isExternalReloadPending)
    }

    @Test("Stopping releases the store and restarting observes edits")
    func stopAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var store: AppSettingsStore? = fixture.makeStore()
        weak let released = store
        store?.bootstrap()
        store?.startWatching()
        store?.stopWatching()
        try fixture.write("Restarted", to: fixture.target)
        store?.startWatching()
        try fixture.write("After restart", to: fixture.target, atomic: false)
        #expect(await waitUntilEventually { store?.workspaces.value.defaultGroup == "After restart" })
        store = nil
        #expect(await waitUntilEventually { released == nil })
    }
}

private struct Fixture {
    let root: URL
    let config: URL
    let target: URL

    init(relativeLink: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("config-watch-\(UUID())")
        config = root.appendingPathComponent("config/config.toml")
        target = root.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("Initial", to: target)
        try FileManager.default.createSymbolicLink(
            atPath: config.path,
            withDestinationPath: relativeLink ? "../dotfiles/config.toml" : target.path
        )
    }

    func write(_ group: String, to url: URL, atomic: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = AwesoMuxConfig.defaultValue
        config.workspaces.defaultGroup = group
        config.unknownTopLevelTables = ["custom": "keep = true\n"]
        try TOMLConfigCodec().encode(config).write(to: url, options: atomic ? .atomic : [])
    }

    @MainActor
    func makeStore() -> AppSettingsStore {
        AppSettingsStore(
            fileStore: ConfigFileStore(configURL: config),
            watchDebounceNanoseconds: 20_000_000,
            legacySnapshotProvider: { nil }
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
