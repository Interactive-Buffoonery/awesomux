import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import awesoMux
import AwesoMuxCore

@Suite("DaemonPolicyStore")
struct DaemonPolicyStoreTests {
    private func id(_ s: String) -> TerminalSessionID { TerminalSessionID(rawValue: s)! }
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("amx-pins-\(UUID().uuidString).json")
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("amx-pins-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("pin persists and round-trips across instances")
    func roundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DaemonPolicyStore(fileURL: url)
        store.setPinned(true, for: id(a))
        #expect(store.pinnedIDs == [id(a)])
        let reloaded = DaemonPolicyStore(fileURL: url)
        #expect(reloaded.pinnedIDs == [id(a)])
    }

    @Test("unpin removes the id")
    func unpin() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DaemonPolicyStore(fileURL: url)
        store.setPinned(true, for: id(a))
        store.setPinned(false, for: id(a))
        #expect(store.pinnedIDs.isEmpty)
    }

    @Test("prunePins drops ids no longer live")
    func prune() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DaemonPolicyStore(fileURL: url)
        store.setPinned(true, for: id(a))
        store.setPinned(true, for: id(b))
        store.prunePins(keepingOnly: [id(a)])
        #expect(store.pinnedIDs == [id(a)])
    }

    @Test("missing file starts empty, corrupt file tolerated")
    func resilience() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DaemonPolicyStore(fileURL: url).pinnedIDs.isEmpty)
        try? Data("{ not json".utf8).write(to: url)
        #expect(DaemonPolicyStore(fileURL: url).pinnedIDs.isEmpty)
    }

    @Test("default-location initializer accepts an injected support directory")
    func injectedSupportDirectory() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DaemonPolicyStore(supportDirectoryURL: directory)

        store.setPinned(true, for: id(a))

        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("daemon-pins.json").path
        ))
        #expect(DaemonPolicyStore(
            fileURL: directory.appendingPathComponent("daemon-pins.json")
        ).pinnedIDs == [id(a)])
    }
}
