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
/// `WorkspaceLayoutPreset`'s responsibility; this type is the in-memory intent
/// value plus a stable Codable shape, not the persisted preset format. `Node`
/// is a recursive `indirect enum` decoded from untrusted preset files, so
/// `SplitIntent.init(from:)` bounds nesting depth (mirroring `TerminalSplit`'s
/// `maxDecodedSplitDepth` guard) — a deeply nested preset would otherwise
/// stack-overflow the recursive decoder. Like that guard, it bounds only the
/// Codable recursion; callers decoding untrusted BYTES must also run the
/// byte-level nesting pre-scan before `JSONDecoder` (see `LayoutPresetStore`).
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
            // Preset files are untrusted (checked into repos, shared), and
            // `Node` recursion is unbounded in the wire format. Count ancestor
            // `first`/`second` keys exactly like `TerminalSplit.init(from:)`
            // and reuse its cap so the two decode guards can never drift. The
            // guard lives here, in the type, so EVERY intent decode is bounded
            // regardless of call site.
            let splitDepth = decoder.codingPath.count {
                $0.stringValue == CodingKeys.first.stringValue
                    || $0.stringValue == CodingKeys.second.stringValue
            }
            guard splitDepth < TerminalSplit.maxDecodedSplitDepth else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: """
                            WorkspaceLayoutIntent nesting exceeds the decode limit of \
                            \(TerminalSplit.maxDecodedSplitDepth) splits; preset rejected to \
                            avoid unbounded decode recursion.
                            """
                    )
                )
            }

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

public extension WorkspaceLayoutIntent {
    /// Number of terminal leaves. Used by `WorkspaceLayoutPreset` to bound how
    /// many panes an untrusted preset can create on apply.
    var terminalCount: Int { root.terminalCount }

    /// Number of nested split levels (a lone terminal is 0). Used by
    /// `WorkspaceLayoutPreset` to keep applied presets well under the restore
    /// contract's `SessionRestoreReducer.maxRestoredLayoutDepth`.
    var splitDepth: Int { root.splitDepth }

    /// Reverse of `TerminalPaneLayout.layoutIntent`: build a live layout from
    /// this intent, minting FRESH identity everywhere (pane IDs, terminal
    /// session IDs, split IDs). Every pane is a local terminal
    /// (`PaneExecutionPlan.local`) rooted at `workingDirectory` — an intent has
    /// no field that could say otherwise, so applying a preset can never target
    /// a remote host or execute anything beyond normal pane creation.
    ///
    /// Geometry semantics: the intent preserves SURVIVING split boundaries from
    /// the projection, not pruned-sibling proportions — a materialized layout
    /// reproduces the surviving split structure with its recorded (clamped)
    /// fractions, which may differ from the visible proportions of the layout
    /// the preset was saved from if panes were pruned at save time.
    ///
    /// Titles come from untrusted preset bytes, so they pass through the same
    /// `SessionStoreText.sanitizedTitle` hygiene as every other title source; a
    /// title that sanitizes to empty falls back to the directory basename
    /// (matching `PaneLayoutReducer`'s fresh-pane seed).
    func materialize(workingDirectory: String) -> TerminalPaneLayout {
        root.materialized(workingDirectory: workingDirectory)
    }
}

extension WorkspaceLayoutIntent.Node {
    var terminalCount: Int {
        switch self {
        case .terminal: 1
        case let .split(split): split.first.terminalCount + split.second.terminalCount
        }
    }

    var splitDepth: Int {
        switch self {
        case .terminal: 0
        case let .split(split): 1 + max(split.first.splitDepth, split.second.splitDepth)
        }
    }

    fileprivate func materialized(workingDirectory: String) -> TerminalPaneLayout {
        switch self {
        case let .terminal(intent):
            let pinnedTitle = intent.title
                .map(SessionStoreText.sanitizedTitle)
                .flatMap { $0.isEmpty ? nil : $0 }
            let basename = (workingDirectory as NSString).lastPathComponent
            let fallbackTitle = basename.isEmpty ? workingDirectory : basename
            return .pane(
                TerminalPane(
                    title: pinnedTitle ?? fallbackTitle,
                    isTitleUserEdited: pinnedTitle != nil,
                    workingDirectory: workingDirectory,
                    color: intent.color,
                    executionPlan: .local
                )
            )

        case let .split(intent):
            return .split(
                TerminalSplit(
                    orientation: intent.orientation,
                    first: intent.first.materialized(workingDirectory: workingDirectory),
                    second: intent.second.materialized(workingDirectory: workingDirectory),
                    firstFraction: intent.firstFraction
                )
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
