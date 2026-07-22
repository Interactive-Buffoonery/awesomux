import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

/// Pins for the session manager: the user "forever" backstop that exempts a
/// daemon from idle/age reaping. Persisted as app-support JSON — NOT config.toml,
/// because pins are keyed by ephemeral, machine-local daemon UUIDs that mean
/// nothing in a portable human-edited config (see design spec §8).
final class DaemonPolicyStore {
    private struct Payload: Codable { var pins: [String] }

    private let fileURL: URL
    private var pins: Set<TerminalSessionID>

    /// Default location: the current profile's Application Support directory.
    convenience init(supportDirectoryURL: URL = SessionPersistence.supportDirectoryURL) {
        let base = supportDirectoryURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.init(fileURL: base.appendingPathComponent("daemon-pins.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        // Tolerate missing/corrupt: a malformed pins file must not crash launch;
        // worst case is the user re-pins. Start empty and let the next save heal it.
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            pins = Set(payload.pins.compactMap(TerminalSessionID.init(rawValue:)))
        } else {
            pins = []
        }
    }

    var pinnedIDs: Set<TerminalSessionID> { pins }

    func setPinned(_ pinned: Bool, for id: TerminalSessionID) {
        if pinned { pins.insert(id) } else { pins.remove(id) }
        persist()
    }

    /// Drop pins for daemons no longer in `amx list` (reaped ids never return),
    /// so the file can't grow unbounded.
    func prunePins(keepingOnly liveIDs: Set<TerminalSessionID>) {
        let kept = pins.intersection(liveIDs)
        guard kept != pins else { return }
        pins = kept
        persist()
    }

    private func persist() {
        let payload = Payload(pins: pins.map(\.rawValue).sorted())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
