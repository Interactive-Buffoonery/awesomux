import Foundation

public struct TerminalSplit: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var orientation: TerminalSplitOrientation
    public var first: TerminalPaneLayout
    public var second: TerminalPaneLayout
    public private(set) var firstFraction: Double

    public init(
        id: UUID = UUID(),
        orientation: TerminalSplitOrientation,
        first: TerminalPaneLayout,
        second: TerminalPaneLayout,
        firstFraction: Double = 0.5
    ) {
        self.id = id
        self.orientation = orientation
        self.first = first
        self.second = second
        self.firstFraction = firstFraction.clampedSplitFraction
    }
}
public extension TerminalSplit {
    /// Rebuild this split preserving `id`/`orientation`/`firstFraction`, swapping
    /// one or both children (or the fraction). Every structural mutation used to
    /// re-spell the full `TerminalSplit(id:orientation:first:second:firstFraction:)`
    /// initializer by hand (13+ sites); centralizing it here means the preserved
    /// fields can never silently drift between call sites, and a new leaf kind
    /// reuses this rebuild instead of adding another copy.
    func rebuilding(
        first: TerminalPaneLayout? = nil,
        second: TerminalPaneLayout? = nil,
        firstFraction: Double? = nil
    ) -> TerminalSplit {
        TerminalSplit(
            id: id,
            orientation: orientation,
            first: first ?? self.first,
            second: second ?? self.second,
            firstFraction: firstFraction ?? self.firstFraction
        )
    }
}

extension TerminalSplit {
    private enum CodingKeys: String, CodingKey {
        case id
        case orientation
        case first
        case second
        case firstFraction
    }

    /// Maximum number of ancestor split levels tolerated before a decode is
    /// rejected. `TerminalSplit` is the *only* nesting node in a
    /// `TerminalPaneLayout` (`.pane`/`.document` are leaves), so bounding the
    /// recursion here bounds the whole tree. At entry to `init(from:)` the
    /// coding path already carries one `first`/`second` key per ancestor split
    /// (the enum's synthesized wrapper adds `split`/`_0` keys, which do not
    /// count) — so `splitDepth < maxDecodedSplitDepth` admits at most 96 nested
    /// splits and throws on the 97th.
    ///
    /// Why 96 — it clears two lower bounds and stays under an upper one:
    /// - Above the max *legal* nesting. The use-time guard
    ///   `SessionRestoreReducer.maxRestoredLayoutDepth` (64) is a `layoutDepth`
    ///   (nodes), i.e. at most 63 splits; 96 admits every layout that use-time
    ///   would accept, so legal snapshots decode and are never rejected here.
    /// - Above the disk pre-scan's reach. `SessionPersistence.load` rejects any
    ///   snapshot whose JSON nesting exceeds `maxSnapshotNestingDepth` (256
    ///   braces) before decoding; the real session-state format spends 3 braces
    ///   per split level plus a fixed wrapper, so at most ~82 splits survive
    ///   that scan. Keeping the cap above that means the disk path never trips
    ///   *this* guard — anything the pre-scan admits decodes fully and reaches
    ///   use-time, preserving per-session recovery granularity (a single
    ///   over-deep session collapses; siblings survive) instead of quarantining
    ///   the whole snapshot. `SessionPersistenceLoadTests` locks this coupling
    ///   by asserting a snapshot nested to this cap is already rejected by the
    ///   pre-scan.
    /// - Far below any stack-overflow depth (thousands of frames), so a crafted
    ///   snapshot with tens of thousands of nested splits is rejected long
    ///   before the recursion blows the stack.
    ///
    /// Scope: this bounds *Codable* recursion at every decode call site. Two
    /// honest limits: the guard only fires after the decoder has already
    /// recursed to the cap, so the cap must itself be stack-safe on the calling
    /// thread (96 levels is, on the main-thread restore path); and it does NOT
    /// bound the JSON *parser*'s own recursion — a naked `JSONDecoder().decode`
    /// on hostile bytes could overflow inside the scanner before `init(from:)`
    /// runs. The untrusted-bytes path (`SessionPersistence.load`) guards both by
    /// running the linear byte-level nesting pre-scan noted above before decode.
    static let maxDecodedSplitDepth = 96

    public init(from decoder: Decoder) throws {
        let splitDepth = decoder.codingPath.count {
            $0.stringValue == CodingKeys.first.stringValue
                || $0.stringValue == CodingKeys.second.stringValue
        }
        guard splitDepth < Self.maxDecodedSplitDepth else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: """
                        TerminalPaneLayout nesting exceeds the decode limit of \
                        \(Self.maxDecodedSplitDepth) splits; snapshot rejected to \
                        avoid unbounded decode recursion.
                        """
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        let first = try TerminalPaneLayout.decodeRecoveringEmptyDocumentGroup(
            from: container.superDecoder(forKey: .first)
        )
        let second = try TerminalPaneLayout.decodeRecoveringEmptyDocumentGroup(
            from: container.superDecoder(forKey: .second)
        )
        guard let first, let second else {
            guard let survivingLayout = first ?? second else {
                throw CollapsedTerminalSplitDecodingError(survivingLayout: nil)
            }
            throw CollapsedTerminalSplitDecodingError(survivingLayout: survivingLayout)
        }

        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            orientation: try container.decode(TerminalSplitOrientation.self, forKey: .orientation),
            first: first,
            second: second,
            firstFraction: try container.decodeIfPresent(Double.self, forKey: .firstFraction) ?? 0.5
        )
    }
}

struct CollapsedTerminalSplitDecodingError: Error {
    let survivingLayout: TerminalPaneLayout?
}

public enum TerminalSplitOrientation: String, Codable, Hashable, Sendable {
    case vertical
    case horizontal
}

public enum PaneFocusDirection: Hashable, Sendable {
    case next
    case previous
}

/// A spatial edge a pane can be dragged to, either of the whole workspace or of
/// another pane. `left`/`right` produce a side-by-side (`.vertical`) split;
/// `up`/`down` produce a stacked (`.horizontal`) split. The moved pane lands as
/// the split's `first` for `left`/`up` and its `second` for `right`/`down`,
/// matching the HStack/VStack rendering in `TerminalPaneView`.
public enum PaneMoveEdge: Hashable, Sendable {
    case up
    case down
    case left
    case right

    /// The split orientation a drop onto this edge produces.
    var orientation: TerminalSplitOrientation {
        switch self {
        case .left, .right:
            .vertical
        case .up, .down:
            .horizontal
        }
    }

    /// Whether the moved pane occupies the split's `first` slot (top / left)
    /// rather than `second` (bottom / right).
    var placesMovedPaneFirst: Bool {
        switch self {
        case .up, .left:
            true
        case .down, .right:
            false
        }
    }
}

private extension Double {
    var clampedSplitFraction: Double {
        guard isFinite else {
            return 0.5
        }

        return min(max(self, 0.15), 0.85)
    }
}
