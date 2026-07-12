/// What a tile's status dot shows in the collapsed (60px) rail.
///
/// `needs` / `error` keep a glyph because "this workspace needs you" is the
/// one signal a user can't afford to miss in peripheral vision, and a
/// same-shape dot distinguished only by hue fails for color-blind users.
/// `idle` renders nothing — absence of a dot *is* the idle signal.
public enum CollapsedStatusBadge: Equatable, Sendable {
    /// The closed set of glyphs that survive the dot-only collapse. A discrete
    /// enum (not a free `String`) keeps the valid set tight so callers can't
    /// construct an arbitrary `.glyph("X")`.
    public enum Glyph: String, Equatable, Sendable {
        case exclamation = "!"
        case cross = "✕"
    }

    case glyph(Glyph)
    case dot

    public static func resolve(for state: AwState) -> CollapsedStatusBadge? {
        switch state {
        case .idle:
            return nil
        case .needs:
            return .glyph(.exclamation)
        case .error:
            return .glyph(.cross)
        case .thinking, .done, .output, .waiting, .running:
            return .dot
        }
    }
}
