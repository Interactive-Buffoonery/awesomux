import Foundation

/// A pane's name-plate color. Tagged so future color *sources* — e.g. a slot
/// pulled from an imported iTerm/Ghostty theme — slot in as a new case without
/// migrating already-persisted `.palette` values. v1 only ever produces
/// `.palette`. A value written by a newer build fails to decode here on
/// purpose — either an unknown `kind` (a future color *source*) or an unknown
/// `name` (a `WorkspaceGroupColor` case this build doesn't have yet);
/// `TerminalPane` swallows both into `nil` so one forward-written pane can't
/// quarantine a whole workspace snapshot.
///
/// **Known, accepted limitation — lossy/destructive forward-compat downgrade:**
/// an older build that opens a snapshot containing a future/unknown color will
/// decode it to `nil` and *erase* it on the next save. The pane's color is lost
/// permanently from that point. This is acceptable pre-1.0 — there is a single
/// user who controls which build they are running, so the risk of a silent
/// downgrade is low. `nil`-on-unknown is what prevents a crash or snapshot
/// quarantine; preserving the raw bytes via an `.unknown(raw)` case was
/// explicitly rejected in favour of this simpler contract.
public enum PaneColor: Codable, Hashable, Sendable {
    case palette(WorkspaceGroupColor)

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case palette
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // No @unknown default here: an unknown `kind` string causes the
        // `Kind.init(from:)` decode to throw, which propagates up before this
        // switch is reached. `decodeTolerantColor` in `TerminalPane` catches that
        // throw and maps it to `nil`. Do NOT add a default case — it would silently
        // swallow future unknown kinds instead of letting the tolerant decoder handle
        // them cleanly.
        switch try container.decode(Kind.self, forKey: .kind) {
        case .palette:
            self = .palette(try container.decode(WorkspaceGroupColor.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .palette(let color):
            try container.encode(Kind.palette, forKey: .kind)
            try container.encode(color, forKey: .name)
        }
    }
}
