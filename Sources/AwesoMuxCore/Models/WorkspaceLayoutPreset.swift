import Foundation

/// The persisted, versioned wire format for a named layout preset file
/// (`.awesomux/layouts/<name>.json`, INT-757). Wraps a `WorkspaceLayoutIntent`
/// with an explicit schema version so a file written by a newer build fails
/// loudly here instead of half-decoding.
///
/// Preset files are UNTRUSTED input — checked into repos and shared across
/// teams — so decode enforces, in order:
/// 1. `version == currentVersion` exactly (0, negative, and future versions
///    all throw `WorkspaceLayoutPresetError.unsupportedVersion`; a missing or
///    non-integer version is a plain `DecodingError`, i.e. a malformed file).
/// 2. The intent's own decoder-level nesting guard
///    (`WorkspaceLayoutIntent.SplitIntent.init(from:)`).
/// 3. Semantic caps validated before any pane could be created: `maxSplitDepth`
///    and `maxTerminalCount`. These are deliberately far below
///    `SessionRestoreReducer.maxRestoredLayoutDepth` (64) so an applied preset
///    survives the persist/restore contract instead of collapsing on next
///    launch, and they bound how many terminals an untrusted file can spawn.
///
/// Unknown JSON fields are tolerated (keyed decode ignores extras) so older
/// builds keep reading files that a future version extended compatibly; an
/// unknown `Node` case is NOT tolerated and fails the decode.
public struct WorkspaceLayoutPreset: Hashable, Sendable, Codable {
    public static let currentVersion = 1
    /// A split tree with `maxTerminalCount` leaves is at most
    /// `maxTerminalCount - 1` levels deep (a pure chain), so a larger depth cap
    /// would be dead policy the terminal cap always rejects first. Keeping the
    /// caps coupled makes the boundary reachable and testable.
    public static let maxSplitDepth = maxTerminalCount - 1
    public static let maxTerminalCount = 16

    public let version: Int
    public let layout: WorkspaceLayoutIntent

    /// Save-side construction: always stamps the current version. Callers save
    /// only intents projected from live layouts, which are structurally within
    /// the caps by construction (a live layout deep enough to exceed them
    /// cannot exist under the restore contract).
    public init(layout: WorkspaceLayoutIntent) {
        self.version = Self.currentVersion
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case layout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw WorkspaceLayoutPresetError.unsupportedVersion(version)
        }

        let layout = try container.decode(WorkspaceLayoutIntent.self, forKey: .layout)
        guard layout.splitDepth <= Self.maxSplitDepth else {
            throw WorkspaceLayoutPresetError.layoutTooDeep(
                depth: layout.splitDepth,
                limit: Self.maxSplitDepth
            )
        }
        guard layout.terminalCount <= Self.maxTerminalCount else {
            throw WorkspaceLayoutPresetError.tooManyTerminals(
                count: layout.terminalCount,
                limit: Self.maxTerminalCount
            )
        }

        self.version = version
        self.layout = layout
    }
}

public enum WorkspaceLayoutPresetError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case layoutTooDeep(depth: Int, limit: Int)
    case tooManyTerminals(count: Int, limit: Int)
}
