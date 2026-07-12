import AwesoMuxCore
import Foundation

/// Pure decision helper: should a Path Bar resolve re-fire walk the repo NOW, or
/// be debounced because only the terminal title churned?
///
/// `TerminalPathBarView`'s `.task(id: resolveKey)` re-fires whenever any key field
/// changes — including `paneTitle`, which agent TUIs (Claude Code, Codex) rewrite
/// many times per second over OSC while "thinking" (spinner / token count).
/// `TerminalPathBarModel.make()` is an UNCACHED filesystem walk + git HEAD read, so
/// reacting to every title tick burned CPU and stuttered scroll (INT-523). The chip
/// resolvers are already TTL-cached; `make()` is the cost.
///
/// We can't simply drop `paneTitle` from the key: title reactivity is load-bearing
/// for one case — an in-place `git checkout` leaves cwd unchanged and only rewrites
/// the prompt-embedded title, and that title change is how the branch chip learns to
/// refresh. So we keep title in the key but DEBOUNCE it. This classifier compares the
/// inputs that actually change `make()`'s OUTPUT (cwd / pane / remote / focus); when
/// those are unchanged the re-fire is title-only churn → debounce, otherwise resolve
/// immediately. The view enacts the wait via `.task(id:)`'s cancel-on-key-change, so
/// a fast spinner keeps cancelling the pending walk until the title settles.
///
/// Side-effect free; tests live in `TerminalPathBarResolvePolicyTests`.
enum TerminalPathBarResolvePolicy {
    /// The inputs that drive the expensive `make()` output. Deliberately excludes
    /// `paneTitle` / `fallbackProject` (display-only churn) so a title-only change
    /// compares equal here and is classified as debounceable.
    struct ResolveInputs: Equatable {
        var activePaneID: TerminalPane.ID?
        var workingDirectory: String
        var remoteHost: String?
        var remoteConnectionHealth: RemoteConnectionHealth
        var isActive: Bool

        init(
            activePaneID: TerminalPane.ID?,
            workingDirectory: String,
            remoteHost: String?,
            remoteConnectionHealth: RemoteConnectionHealth,
            isActive: Bool
        ) {
            self.activePaneID = activePaneID
            self.workingDirectory = workingDirectory
            self.remoteHost = remoteHost
            self.remoteConnectionHealth = remoteConnectionHealth
            self.isActive = isActive
        }
    }

    enum Refire: Equatable {
        /// First paint, or a substantive change (cwd / pane / remote / focus) — walk now.
        case immediate
        /// Only the title changed — wait for it to settle before walking the repo.
        case debounced
    }

    /// Debounce window for title-only churn. 500ms collapses a multi-Hz "thinking"
    /// spinner to at most one walk once the title settles; an in-place checkout's
    /// branch chip still refreshes within this window (chips aren't latency-critical).
    static let titleSettleDelay: Duration = .milliseconds(500)

    /// `.immediate` when there is no prior resolve (first paint) or a make()-affecting
    /// input changed; `.debounced` when the only thing that could have changed is the
    /// excluded title. A title that *settles* slower than `titleSettleDelay` still
    /// resolves once per settle — if a steady ~1Hz-settling title ever shows cost, the
    /// upgrade path is a min-interval throttle on title-only resolves (a clock check
    /// here), not lowering the window.
    static func classify(previous: ResolveInputs?, current: ResolveInputs) -> Refire {
        guard let previous, previous == current else { return .immediate }
        return .debounced
    }
}
