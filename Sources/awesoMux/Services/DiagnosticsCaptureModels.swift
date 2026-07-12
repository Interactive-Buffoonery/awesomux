import AwesoMuxCore

enum DiagnosticsCapturePurpose: Equatable, Sendable {
    /// Timed sample. Optionally re-runs `amx list` (every Nth sample) and carries the
    /// last-known daemon-list availability so partial refresh state stays honest.
    case sample(
        knownDaemons: [LiveDaemon],
        rediscoverDaemons: Bool,
        daemonListAvailable: Bool
    )
    /// Manual refresh. Falls back to `fallbackDaemons` when list discovery fails.
    case refresh(fallbackDaemons: [LiveDaemon])

    var isRefresh: Bool {
        if case .refresh = self { return true }
        return false
    }

    var isSample: Bool {
        if case .sample = self { return true }
        return false
    }
}

struct DiagnosticsCaptureResult: Sendable {
    let snapshot: DiagnosticsProcessSnapshot
    let discoveredDaemons: [LiveDaemon]?
}
