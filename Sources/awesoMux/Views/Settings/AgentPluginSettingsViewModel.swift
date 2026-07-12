import AwesoMuxConfig
import Foundation
import SwiftUI

// MARK: - AgentPluginOpKind

/// Which kind of async op is in flight for a provider. A probe is read-only and
/// cancellation-safe; a mutation is not (the CLI op runs to completion regardless,
/// so cancelling only discards its result). The card uses this to gate Cancel.
enum AgentPluginOpKind: Sendable {
    case probe
    case mutation
}

// MARK: - AgentPluginProbeState

/// Lifecycle of a provider's status probe. `unprobed` means nothing has run yet
/// (show a real status fallback); `probing` means a probe started but has not
/// resolved (show neutral "Checking", even after cancellation); `probed` means at
/// least one report has landed. A cancelled probe stays `probing`, which is what
/// keeps the card on "Checking" instead of a wrong terminal state until the next
/// probe resolves it.
enum AgentPluginProbeState: Sendable {
    case unprobed
    case probing
    case probed
}

// MARK: - AgentPluginCardState

/// View-facing snapshot of a CLI-driven provider card. Pure `Sendable` data so it
/// can be derived off the `@MainActor` and published back. The runner and its
/// `CommandRunner`/app-server types never leak into the view.
struct AgentPluginCardState: Equatable, Sendable {
    var provider: AgentPluginProvider
    var title: String
    var subtitle: String
    var binaryPlaceholder: String
    var configHomePlaceholder: String
    var configHomeLabel: String
    var status: AgentPluginStatus
    /// The rendered plugin marketplace source on disk, when one exists.
    var renderedSourcePath: String?
    /// The resolved `awesoMuxAgentHook` path baked into the hook config.
    var helperPath: String?
    /// Set when the helper lives under a `dist/` dev build; the card warns that a
    /// release build is needed for a durable install (ADR-0012 decision 3).
    var distWarning: String?
    /// Non-blocking advisory from the latest probe (e.g. live-vs-recorded config
    /// home drift), rendered as a caution banner like `distWarning`.
    var note: String?
    /// Transient post-mutation guidance (reload/review), shown once after an action.
    var guidance: String?
    /// Concise failure summary, with `diagnostics` carrying the expandable detail.
    var failureSummary: String?
    var diagnostics: AgentPluginDiagnostics?
    /// True while an async op is in flight; the card disables its action row.
    var isBusy: Bool
    /// The kind of op currently in flight, if any. Drives the Cancel affordance:
    /// only a probe is safe to cancel (its transport closes cleanly), so Cancel is
    /// offered for `.probe` and never for `.mutation` (the CLI mutation is not
    /// cancellation-aware — killing it orphans the process, §performPluginAction).
    var inflightOp: AgentPluginOpKind?
    /// True while the card should read as neutral "Checking" rather than a real
    /// status: a probe has started but no report has landed yet. Distinct from
    /// `isBusy` so it survives a cancelled probe (the flag is keyed off "probe
    /// started, no report yet", which a cancelled probe still satisfies) — the card
    /// shows Checking, not a stale `.notInstalled`, and the next probe resolves it.
    var isCheckingInitialStatus: Bool
    /// True when a probe is in flight and can be cancelled from the card.
    var canCancel: Bool { inflightOp == .probe }
    /// True only for the Codex state where status still reflects a recorded
    /// install that needs review, but Repair can reconcile the live CODEX_HOME.
    var allowsDriftRepair: Bool
    /// View-ready status label, which may differ from the underlying status
    /// label while the first status check is running.
    var statusLabel: String

    var allowsEnable: Bool { status.allowsEnable && !isBusy }
    var allowsRepair: Bool { (status.allowsRepair || allowsDriftRepair) && !isBusy }
    var allowsDisable: Bool { status.allowsDisable && !isBusy }
    var allowsUninstall: Bool { status.allowsUninstall && !isBusy }
}

// MARK: - AgentPluginSettingsViewModel

@Observable
@MainActor
final class AgentPluginSettingsViewModel {
    private let runner: AgentPluginRunner
    private let helperPathResolver: () -> AgentHookHelperPath?
    private let renderedSourcePathProvider: (AgentPluginProvider) -> String?

    /// Latest status per provider. `nil` until the first probe completes.
    private(set) var reports: [AgentPluginProvider: AgentPluginStatusReport] = [:]
    private(set) var busy: Set<AgentPluginProvider> = []
    /// The op kind in flight per provider, set on entry and cleared alongside
    /// `busy`. Absent ⇒ idle. Gates the card's Cancel affordance (#8).
    private(set) var inflightOp: [AgentPluginProvider: AgentPluginOpKind] = [:]
    /// Probe lifecycle per provider (#9). Absent ⇒ `.unprobed`. Set to `.probing`
    /// synchronously before the first probe `await`, `.probed` once a report is
    /// assigned; a cancelled probe intentionally stays `.probing`.
    private(set) var probeState: [AgentPluginProvider: AgentPluginProbeState] = [:]
    /// Transient guidance/failure surfaced by the last action, cleared on the next.
    private(set) var actionGuidance: [AgentPluginProvider: String] = [:]
    private(set) var actionFailures: [AgentPluginProvider: AgentPluginActionOutcome] = [:]
    // Key absent ⇒ no rendered source path for that provider. Storing `String`
    // (not `String?`) avoids a double-optional every reader would have to flatten;
    // assigning the provider's `String?` to the subscript sets-or-removes the key.
    private(set) var renderedSourcePaths: [AgentPluginProvider: String] = [:]

    #if DEBUG
    /// Providers with an injected sample diagnostics payload (see the DEBUG-only
    /// extension). Compiled out of release builds.
    private var debugSampleProviders: Set<AgentPluginProvider> = []
    #endif

    init(
        runner: AgentPluginRunner = ProcessAgentPluginRunner(),
        helperPathResolver: @escaping () -> AgentHookHelperPath? = { AgentHookHelperPath.resolve() },
        renderedSourcePathProvider: @escaping (AgentPluginProvider) -> String? = { provider in
            let renderer = AgentPluginTemplateRenderer()
            let url = renderer.renderedTreeURL(provider: provider)
            return renderer.fileManager.fileExists(atPath: url.path) ? url.path : nil
        }
    ) {
        self.runner = runner
        self.helperPathResolver = helperPathResolver
        self.renderedSourcePathProvider = renderedSourcePathProvider
        for provider in AgentPluginProvider.allCases {
            renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
        }
    }

    /// Clears cached probe/action state so the card does not show a stale status
    /// after an external config change.
    func clearCachedState(for provider: AgentPluginProvider) {
        reports[provider] = nil
        actionFailures[provider] = nil
        actionGuidance[provider] = nil
        probeState[provider] = .unprobed
        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
    }

    // MARK: Card state

    func cardState(provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> AgentPluginCardState {
        let helper = helperPathResolver()
        let report = reports[provider]
        let status = setup.enabled
            ? (report?.status ?? .notInstalled)
            : .notConfigured
        // Neutral "Checking" the moment a probe starts and until the first report
        // lands — keyed off the probe *having started* (not `busy`), so a cancelled
        // probe still reads as Checking rather than flashing the `.notInstalled`
        // fallback, and the next probe resolves it (#9).
        let isCheckingInitialStatus = setup.enabled
            && reports[provider] == nil
            && (probeState[provider] ?? .unprobed) != .unprobed
        let allowsDriftRepair = setup.enabled
            && provider == .codex
            && report?.hasConfigHomeDrift == true
            && {
                if case .needsReview = status { return true }
                return false
            }()

        return AgentPluginCardState(
            provider: provider,
            title: provider.displayName,
            subtitle: provider.subtitle,
            binaryPlaceholder: provider.defaultBinaryPath,
            configHomePlaceholder: provider.defaultConfigHomePlaceholder,
            configHomeLabel: provider.configHomeLabel,
            status: status,
            renderedSourcePath: renderedSourcePaths[provider],
            helperPath: helper?.path,
            distWarning: (helper?.isDevelopmentBundle ?? false)
                ? "This is a dist/ development build. The status hook breaks if that build folder is removed; use a release build for a durable install."
                : nil,
            note: setup.enabled ? report?.note : nil,
            guidance: actionGuidance[provider],
            failureSummary: failureSummary(provider: provider, status: status),
            diagnostics: diagnostics(provider: provider),
            isBusy: busy.contains(provider),
            inflightOp: inflightOp[provider],
            isCheckingInitialStatus: isCheckingInitialStatus,
            allowsDriftRepair: allowsDriftRepair,
            statusLabel: isCheckingInitialStatus ? "Checking" : status.label
        )
    }

    /// Diagnostics come from a failed action first, then a failed probe — a
    /// non-zero `claude plugin list` attaches diagnostics to the status report,
    /// and the card must surface that stderr just as it does for a failed action.
    private func diagnostics(provider: AgentPluginProvider) -> AgentPluginDiagnostics? {
        actionFailures[provider]?.diagnostics ?? reports[provider]?.diagnostics
    }

    /// A failure summary is shown when either an action or a probe carried
    /// diagnostics. For a probe, the failing status' detail is the summary.
    private func failureSummary(provider: AgentPluginProvider, status: AgentPluginStatus) -> String? {
        if let actionSummary = actionFailures[provider].flatMap(Self.failureSummary) {
            return actionSummary
        }
        if reports[provider]?.diagnostics != nil {
            return status.detail
        }
        return nil
    }

    // MARK: Confirmation

    func confirmation(
        for action: AgentPluginAction,
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) -> AgentPluginConfirmation {
        runner.confirmation(for: action, provider: provider, setup: setup)
    }

    // MARK: Async ops

    /// Read-only probe; safe to run automatically on enable (consent boundary).
    func refreshStatus(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async {
        guard setup.enabled else {
            reports[provider] = nil
            actionFailures[provider] = nil
            actionGuidance[provider] = nil
            renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
            busy.remove(provider)
            inflightOp[provider] = nil
            probeState[provider] = .unprobed
            return
        }
        guard !busy.contains(provider) else { return }
        busy.insert(provider)
        inflightOp[provider] = .probe
        // Set synchronously, before the first `await`: the card must read as
        // Checking from the instant the probe starts, and this must persist through
        // a cancellation (which returns below without ever reaching `.probed`).
        probeState[provider] = .probing
        defer {
            busy.remove(provider)
            inflightOp[provider] = nil
        }

        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
        let report = await runner.status(provider: provider, setup: setup)
        // A cancelled probe leaves `probeState` at `.probing` on purpose: the card
        // keeps showing Checking (not a wrong terminal state) until a later probe
        // resolves it, rather than stranding on a stale fallback.
        guard !Task.isCancelled else { return }
        reports[provider] = report
        probeState[provider] = .probed
        // A fresh probe supersedes a prior action's transient state: a stale red
        // failure or reload guidance must not linger over a newly healthy status.
        actionFailures[provider] = nil
        actionGuidance[provider] = nil
    }

    func perform(
        action: AgentPluginAction,
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async {
        guard setup.enabled else { return }
        guard !busy.contains(provider) else { return }
        busy.insert(provider)
        inflightOp[provider] = .mutation
        actionFailures[provider] = nil
        actionGuidance[provider] = nil
        defer {
            busy.remove(provider)
            inflightOp[provider] = nil
        }
        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)

        let outcome: AgentPluginActionOutcome
        switch action {
        case .enableOrInstall:
            outcome = await runner.enableOrInstall(provider: provider, setup: setup)
        case .repair:
            outcome = await runner.repair(provider: provider, setup: setup)
        case .disable:
            outcome = await runner.disable(provider: provider, setup: setup)
        case .uninstall:
            outcome = await runner.uninstall(provider: provider, setup: setup)
        }

        guard !Task.isCancelled else { return }
        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
        reports[provider] = AgentPluginStatusReport(status: outcome.status, diagnostics: outcome.diagnostics)
        // A mutation resolves the status too, so the card leaves the Checking state.
        probeState[provider] = .probed
        if outcome.diagnostics != nil {
            actionFailures[provider] = outcome
        } else if let guidance = outcome.guidance {
            actionGuidance[provider] = guidance
        }
    }

    // MARK: Helpers

    static func failureSummary(_ outcome: AgentPluginActionOutcome) -> String? {
        guard outcome.diagnostics != nil else { return nil }
        return outcome.status.detail
    }
}

#if DEBUG
extension AgentPluginSettingsViewModel {
    /// DEBUG-only affordance to render the real diagnostics disclosure with a
    /// representative payload during development. Injects at the
    /// `AgentPluginDiagnostics?` level `diagnostics(provider:)` already reads, so
    /// the production `diagnosticsDisclosure` render path is exercised unchanged.
    /// Compiled out of release builds — regular users never see it (ADR-0012).
    func isSampleDiagnosticsInjected(for provider: AgentPluginProvider) -> Bool {
        debugSampleProviders.contains(provider)
    }

    func toggleSampleDiagnostics(for provider: AgentPluginProvider) {
        if debugSampleProviders.contains(provider) {
            debugSampleProviders.remove(provider)
            actionFailures[provider] = nil
        } else {
            debugSampleProviders.insert(provider)
            actionFailures[provider] = AgentPluginActionOutcome(
                status: .needsRepair("Sample diagnostics (debug injection)"),
                guidance: nil,
                diagnostics: Self.sampleDiagnostics
            )
        }
    }

    /// A `$HOME`-prefixed path and 60-line stderr so the rendered disclosure shows
    /// the `~` redaction and the `[truncated]` marker (stderr cap is 40 lines).
    private static var sampleDiagnostics: AgentPluginDiagnostics {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentPluginDiagnostics(
            executablePath: "\(home)/.local/bin/claude",
            args: ["plugin", "list", "--json"],
            exitCode: 3,
            rawStdout: "[]",
            rawStderr: (1...60)
                .map { "line \($0): could not read plugin manifest at \(home)/.claude" }
                .joined(separator: "\n"),
            summary: "claude plugin list --json exited 3"
        )
    }
}
#endif
