import AwesoMuxCore
import CoreGraphics
import Foundation

/// Persists each terminal panel mode's user-chosen expanded size, keyed by a
/// per-display bucket so a resize nudge on a laptop screen does not overwrite
/// the size remembered for a large external display (follow-up 4c). Stored as
/// `[bucket: [width, height]]` under one top-level key per mode.
struct TerminalPanelSizeStore {
    private let defaults: UserDefaults
    private let key: String
    private let minimumSize: CGSize

    init(defaults: UserDefaults = .standard, key: String, minimumSize: CGSize) {
        self.defaults = defaults
        self.key = key
        self.minimumSize = minimumSize
    }

    func load(bucket: String) -> CGSize? {
        // A legacy flat `[Double]` (pre-per-display) fails this cast and reads
        // as nil; pre-1.0 drops it silently — the next resize re-seeds it. The
        // companion's existing "com.awesomux.terminalCompanion.size" key holds
        // exactly that flat array today, so upgrading resets companion size once.
        guard let map = defaults.dictionary(forKey: key) as? [String: [Double]],
              let stored = map[bucket], stored.count == 2 else {
            return nil
        }
        let size = CGSize(width: stored[0], height: stored[1])
        guard isValid(size) else { return nil }
        return size
    }

    func save(_ size: CGSize, bucket: String) {
        guard isValid(size) else { return }
        var map = (defaults.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        map[bucket] = [Double(size.width), Double(size.height)]
        defaults.set(map, forKey: key)
    }

    static func bucket(for screenSize: CGSize) -> String {
        "\(Int(screenSize.width.rounded()))x\(Int(screenSize.height.rounded()))"
    }

    // Below-minimum sizes are never legitimate expanded sizes — a stray save of
    // the corner tab's frame once got remembered and reopened the panel collapsed.
    private func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width >= minimumSize.width
            && size.height >= minimumSize.height
    }
}
