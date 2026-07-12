import AppKit

/// What `performKeyEquivalent` should do with a command/control-modified key
/// that libghostty does NOT recognize as a configured binding.
///
/// Mirrors Ghostty's `performKeyEquivalent` default-case state machine
/// (`SurfaceView_AppKit.swift:1319-1385`): a couple of macOS quirk combos
/// (`C-<return>`, `C-/`) pass straight through, and everything else gets one
/// deferred pass through AppKit's own responder chain (in case a system-level
/// key binding wants it) before being redispatched to the terminal if nothing
/// else claimed it.
enum GhosttyKeyEquivalentDecision: Equatable {
    /// Not something this state machine handles — let AppKit continue normally.
    case ignore
    /// A recognized quirk combo (`C-<return>`/`C-/`) — encode `equivalent` now.
    case encode(equivalent: String)
    /// First sighting of this event: defer to AppKit's responder chain.
    case waitForResponderChain
    /// `doCommand` bounced this event back because nothing else claimed it —
    /// encode `equivalent` for the terminal now.
    case redispatch(equivalent: String)
}

/// Pure decision logic extracted from `performKeyEquivalent`/`doCommand` so
/// the state machine is unit-testable without a live `NSEvent`/AppKit runtime
/// (same reasoning as `GhosttyCursorMapper`'s enum extraction: this only needs
/// value types — `NSEvent.ModifierFlags` is a plain `OptionSet`, safe headless).
enum GhosttyKeyEquivalentPolicy {
    /// - Parameters:
    ///   - lastPerformKeyEvent: The timestamp stashed by a prior deferred pass,
    ///     if any.
    /// - Returns: The decision, plus the value `lastPerformKeyEvent` should be
    ///   set to afterward.
    static func decideNonBindingKeyEquivalent(
        charactersIgnoringModifiers: String?,
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        lastPerformKeyEvent: TimeInterval?
    ) -> (decision: GhosttyKeyEquivalentDecision, lastPerformKeyEvent: TimeInterval?) {
        switch charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim (macOS otherwise routes it to
            // the default-button/context-menu key-equivalent machinery).
            guard modifierFlags.contains(.control) else {
                return (.ignore, lastPerformKeyEvent)
            }
            return (.encode(equivalent: "\r"), lastPerformKeyEvent)

        case "/":
            // Treat C-/ as C-_ — macOS beeps on plain C-/ otherwise.
            guard modifierFlags.contains(.control),
                  modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return (.ignore, lastPerformKeyEvent)
            }
            return (.encode(equivalent: "_"), lastPerformKeyEvent)

        default:
            // AppKit sometimes generates synthetic events with a zero
            // timestamp (e.g. Cmd+Period -> "cancel:" -> synthetic Escape).
            // Never process those here.
            guard timestamp != 0 else {
                return (.ignore, lastPerformKeyEvent)
            }

            guard modifierFlags.contains(.command) || modifierFlags.contains(.control) else {
                return (.ignore, nil)
            }

            if let lastPerformKeyEvent, lastPerformKeyEvent == timestamp {
                // This is the redispatched pass of an event we deferred a
                // moment ago (see `doCommand`) — encode it for real now.
                return (.redispatch(equivalent: characters ?? ""), nil)
            }

            // First sighting of this event: let AppKit's own responder chain
            // (potentially a user's system-level key binding) try first.
            return (.waitForResponderChain, timestamp)
        }
    }
}
