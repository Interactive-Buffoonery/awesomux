import Foundation

/// A reusable, serializable description of a workspace's layout STRUCTURE with
/// zero live-only state — the seam INT-757 named presets build on.
///
/// It cannot encode live-only state because it has no field for it: no pane id,
/// `TerminalSessionID`, `PaneExecutionPlan`, working directory, `fileURL`,
/// `ResourceIdentity`, agent state, or remote-cache origin appears anywhere in
/// the type. A `WorkspaceLayoutIntent` is produced only by the prune-and-
/// normalize projection `TerminalPaneLayout.layoutIntent`, never by embedding a
/// `TerminalPane`/`DocumentPane`. The allowlist is locked by a golden encoded
/// key-set test, so adding a field to this type (and thus to the preset schema)
/// fails that test loudly.
///
/// Projection semantics (see `TerminalPaneLayout.layoutIntent`):
/// - Retain only preset-eligible leaves (`WorkspacePaneCapabilities.presetEligible`
///   — local terminals). Document groups and remote terminals are pruned so no
///   file or host identity can reach a shareable preset.
/// - Collapse a split with one pruned child to the surviving child; the pruned
///   split's fraction is dropped with it. Consequence: the intent preserves
///   SURVIVING SPLIT BOUNDARIES, not pruned-sibling pane geometry — if a nested
///   sibling is pruned, the surviving child inherits its parent's slot, not its
///   own former fraction. A preset therefore reproduces the surviving split
///   structure; INT-757 may later normalize applied geometry if approximate
///   visible proportions are wanted.
/// - A layout with no surviving preset-eligible leaf projects to `nil` (a preset
///   needs at least one terminal).
///
/// Split IDs are intentionally omitted: a preset mints fresh identity on apply.
///
/// Wire-format VERSIONING and decode-rejection of unsupported preset files are
/// INT-757's responsibility; this type is the in-memory intent value plus a
/// stable Codable shape, not the persisted preset format. `Node` is a recursive
/// `indirect enum`, so when INT-757 decodes preset files from an untrusted
/// source it MUST bound nesting depth (mirroring `TerminalSplit`'s
/// `maxDecodedSplitDepth` guard) — a deeply nested preset would otherwise
/// stack-overflow the recursive decoder. No untrusted decode path exists yet.
public struct WorkspaceLayoutIntent: Hashable, Sendable, Codable {
    public let root: Node

    public init(root: Node) {
        self.root = root
    }

    public indirect enum Node: Hashable, Sendable, Codable {
        case terminal(TerminalIntent)
        case split(SplitIntent)
    }

    /// The reusable attributes of a terminal leaf. Deliberately tiny: a
    /// user-pinned title (never the live OSC-derived or synthesized title) and
    /// the name-plate color. Nothing that identifies a session, host, path, or
    /// process.
    public struct TerminalIntent: Hashable, Sendable, Codable {
        public let title: String?
        public let color: PaneColor?

        public init(title: String?, color: PaneColor?) {
            self.title = title
            self.color = color
        }
    }

    public struct SplitIntent: Hashable, Sendable, Codable {
        public let orientation: TerminalSplitOrientation
        public let firstFraction: Double
        public let first: Node
        public let second: Node

        public init(
            orientation: TerminalSplitOrientation,
            firstFraction: Double,
            first: Node,
            second: Node
        ) {
            self.orientation = orientation
            self.firstFraction = Self.canonicalFraction(firstFraction)
            self.first = first
            self.second = second
        }

        /// Guards a decoded intent against NaN/inf/out-of-range fractions even
        /// though a projected-from-live intent is already clamped upstream.
        static func canonicalFraction(_ value: Double) -> Double {
            guard value.isFinite else { return 0.5 }
            return min(max(value, 0.15), 0.85)
        }

        private enum CodingKeys: String, CodingKey {
            case orientation
            case firstFraction
            case first
            case second
        }

        // Route decode through the clamping memberwise init — synthesized
        // `init(from:)` would assign `firstFraction` directly and let a hostile
        // preset carry an out-of-range or non-finite fraction.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                orientation: try container.decode(TerminalSplitOrientation.self, forKey: .orientation),
                firstFraction: try container.decode(Double.self, forKey: .firstFraction),
                first: try container.decode(Node.self, forKey: .first),
                second: try container.decode(Node.self, forKey: .second)
            )
        }
    }
}

public extension TerminalPaneLayout {
    /// Prune-and-normalize projection to a preset-eligible `WorkspaceLayoutIntent`.
    /// `nil` when no preset-eligible terminal survives. See
    /// `WorkspaceLayoutIntent` for the full semantics.
    var layoutIntent: WorkspaceLayoutIntent? {
        intentNode().map(WorkspaceLayoutIntent.init(root:))
    }

    private func intentNode() -> WorkspaceLayoutIntent.Node? {
        switch self {
        case let .pane(pane):
            guard WorkspacePaneCapabilities.terminal(pane).presetEligible else {
                return nil
            }
            return .terminal(
                WorkspaceLayoutIntent.TerminalIntent(
                    title: pane.isTitleUserEdited ? pane.title : nil,
                    color: pane.color
                )
            )

        case .documentGroup:
            return nil

        case let .split(split):
            let first = split.first.intentNode()
            let second = split.second.intentNode()
            switch (first, second) {
            case let (.some(first), .some(second)):
                return .split(
                    WorkspaceLayoutIntent.SplitIntent(
                        orientation: split.orientation,
                        firstFraction: split.firstFraction,
                        first: first,
                        second: second
                    )
                )
            case let (.some(survivor), .none),
                let (.none, .some(survivor)):
                return survivor
            case (.none, .none):
                return nil
            }
        }
    }
}
