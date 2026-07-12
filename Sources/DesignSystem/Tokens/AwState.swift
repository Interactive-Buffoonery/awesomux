import Foundation
import SwiftUI

public enum AwState: Int, CaseIterable, Comparable, Sendable {
    case needs = 1
    case error = 2
    case thinking = 3
    case done = 4
    case output = 5
    case waiting = 6
    case running = 7
    case idle = 8

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        localizedLabel()
    }

    public func localizedLabel(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch self {
        case .needs:
            return String(localized: "Needs input", bundle: bundle, locale: locale, comment: "Agent state label")
        case .error:
            return String(localized: "Error", bundle: bundle, locale: locale, comment: "Agent state label")
        case .thinking:
            return String(localized: "Thinking", bundle: bundle, locale: locale, comment: "Agent state label")
        case .done:
            return String(localized: "Done", bundle: bundle, locale: locale, comment: "Agent state label")
        case .output:
            return String(localized: "Output", bundle: bundle, locale: locale, comment: "Agent state label")
        case .waiting:
            return String(localized: "Waiting", bundle: bundle, locale: locale, comment: "Agent state label")
        case .running:
            return String(localized: "Running", bundle: bundle, locale: locale, comment: "Agent state label")
        case .idle:
            return String(localized: "Idle", bundle: bundle, locale: locale, comment: "Agent state label")
        }
    }

    public var color: Color {
        switch self {
        case .needs:
            return .aw.status.needs
        case .error:
            return .aw.status.error
        case .thinking:
            return .aw.status.thinking
        case .done:
            return .aw.status.done
        case .output:
            return .aw.status.output
        case .waiting:
            return .aw.status.waiting
        case .running:
            return .aw.status.running
        case .idle:
            return .aw.status.idle
        }
    }

    public var isLoud: Bool {
        // Saturated peach/red attention-demanders — they get the dark
        // on-loud foreground so contrast holds against the pill tint.
        self == .needs || self == .error
    }
}

/// Cases are SHAPE names (`.play`, `.checkmark`, `.pause`), not state
/// semantics — `.pause` is the glyph the quiet `waiting` state renders
/// (INT-599), not a claim that the agent is suspended. See ADR 0007's
/// INT-599 amendment.
public enum AwStateGlyph: Equatable, Sendable {
    case attention
    case error
    case checkmark
    case outputDot
    case dot
    case pause
    case play
    case spinner

    public static func resolve(for state: AwState) -> AwStateGlyph {
        switch state {
        case .needs:
            return .attention
        case .error:
            return .error
        case .done:
            return .checkmark
        case .output:
            return .outputDot
        case .waiting:
            return .pause
        case .running:
            return .play
        case .thinking:
            return .spinner
        case .idle:
            return .dot
        }
    }

    public var text: String? {
        switch self {
        case .attention:
            return "!"
        case .error:
            return "x"
        case .checkmark, .outputDot, .dot, .play, .spinner, .pause:
            // `.pause` renders as the `pause.fill` SF Symbol, not text. Two
            // vertical bars stay distinct from `.play`'s horizontal triangle,
            // which matters because `waiting`/`running` sit on the
            // tritanopia-adjacent blue/sapphire pair — the shape, not the
            // hue, carries the distinction. (Replaced the old block-cursor
            // bar, which read as a blinking cursor/eye — INT-599.) See
            // AwColor.status.waiting.
            return nil
        }
    }

    /// The paint color `AgentStatusBadge` (`AgentTile.swift`) uses for this
    /// glyph — solid text/icon/dot foreground for the six solid-fill states,
    /// the spinner's stroke, and the idle dot's fill. Extracted to a named,
    /// public, testable symbol (rather than inline per-case colors in the
    /// view) so `AwStateTests` can lock the real production wiring instead of
    /// re-typing a parallel hex table. See INT-361.
    public var badgeForeground: Color {
        switch self {
        case .attention, .error, .checkmark, .outputDot, .pause, .play:
            // Every solid-fill state's glyph needs the same 3:1 non-text
            // floor `onLoud` already held for needs/error — `.play`
            // (running) moved here from `onQuiet` in INT-361 (was 1.31:1 in
            // mocha, functionally invisible).
            Color.aw.status.onLoud
        case .spinner:
            Color.aw.status.thinking
        case .dot:
            Color.aw.textFaint
        }
    }
}
