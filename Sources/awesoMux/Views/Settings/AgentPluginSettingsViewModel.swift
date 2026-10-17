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

// MARK: - AgentPluginTarget

/// One provider config folder. `configHome` is the value passed to the runner
/// as the setup's config home; `nil` means the provider default.
struct AgentPluginTarget: Hashable, Sendable {
    var provider: AgentPluginProvider
    var configHome: String?
}

// MARK: - AgentPluginCardState

/// View-facing snapshot of a CLI-driven provider card. Pure `Sendable` data so it
/// can be derived off the `@MainActor` and published back. The runner and its
/// `CommandRunner`/app-server types never leak into the view.
struct AgentPluginCardState: Equatable, Sendable {
    var target: AgentPluginTarget
    var provider: AgentPluginProvider { target.provider }
    /// The resolved folder this state describes.
    var folderPath: String
    /// True for a folder added from the card, which the card can drop again.
    var canForget: Bool
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
    /// Non-blocking advisory from the latest probe (e.g. an unreadable install
    /// record), rendered as a caution banner like `distWarning`.
    var note: String?
    /// Transient post-mutation guidance (reload/review), shown once after an action.
    var guidance: String?
    /// Concise failure summary, with `diagnostics` carrying the expandable detail.
    var failureSummary: String?
    var diagnostics: AgentPluginDiagnostics?
    /// True while any op for this provider is in flight; the card disables its
    /// actions. Mutations share one install lock, so none starts while a probe
    /// or another mutation of the same provider runs.
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
    /// View-ready status label, which may differ from the underlying status
    /// label while the first status check is running.
    var statusLabel: String

    var allowsEnable: Bool { status.allowsEnable && !isBusy }
    var allowsRepair: Bool { status.allowsRepair && !isBusy }
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

    /// Latest status per folder. `nil` until the first probe completes.
    private(set) var reports: [AgentPluginTarget: AgentPluginStatusReport] = [:]
    /// Folders with a read-only probe in flight. Probes of different folders may
    /// overlap; a second probe of the same folder is refused.
    private(set) var probing: Set<AgentPluginTarget> = []
    /// Providers with a mutation in flight. Mutations share one install lock, so
    /// one runs at a time per provider and never alongside that provider's probes.
    private(set) var mutating: Set<AgentPluginProvider> = []
    /// The op kind in flight per folder, set on entry and cleared alongside
    /// `probing`/`mutating`. Absent ⇒ idle. Gates the card's Cancel affordance (#8).
    private(set) var inflightOp: [AgentPluginTarget: AgentPluginOpKind] = [:]
    /// Probe lifecycle per folder (#9). Absent ⇒ `.unprobed`. Set to `.probing`
    /// synchronously before the first probe `await`, `.probed` once a report is
    /// assigned; a cancelled probe intentionally stays `.probing`.
    private(set) var probeState: [AgentPluginTarget: AgentPluginProbeState] = [:]
    /// Transient guidance/failure surfaced by the last action, cleared on the next.
    private(set) var actionGuidance: [AgentPluginTarget: String] = [:]
    private(set) var actionFailures: [AgentPluginTarget: AgentPluginActionOutcome] = [:]
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
        reports = reports.filter { $0.key.provider != provider }
        actionFailures = actionFailures.filter { $0.key.provider != provider }
        actionGuidance = actionGuidance.filter { $0.key.provider != provider }
        probeState = probeState.filter { $0.key.provider != provider }
        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
    }

    // MARK: Folders

    /// The config field's folder first, then added folders, then the provider
    /// default, then folders that only an install record knows about,
    /// deduplicated by resolved path. The default stays listed when the config
    /// field points elsewhere so an install made there remains manageable.
    func targets(provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> [AgentPluginTarget] {
        let homes =
            [setup.configHome] + (setup.additionalConfigHomes ?? []).map(Optional.some) + [nil]
            + runner.recordedConfigHomes(provider: provider).map(Optional.some)
        var seen: Set<String> = []
        return homes.compactMap { home in
            let target = AgentPluginTarget(provider: provider, configHome: home)
            let resolved = URL(fileURLWithPath: folderPath(target, setup: setup)).resolvingSymlinksInPath().path
            return seen.insert(resolved).inserted ? target : nil
        }
    }

    func setup(for target: AgentPluginTarget, from setup: AgentIntegrationSetup) -> AgentIntegrationSetup {
        var folderSetup = setup
        folderSetup.configHome = target.configHome
        return folderSetup
    }

    private func folderPath(_ target: AgentPluginTarget, setup: AgentIntegrationSetup) -> String {
        URL(fileURLWithPath: runner.pluginConfigHome(provider: target.provider, setup: self.setup(for: target, from: setup)))
            .standardizedFileURL.path
    }

    /// "Installed in N of M folders", or `nil` with a single folder, where the
    /// folder's own status already says it. The count is only given once every
    /// folder has reported whether the plugin is there.
    func installSummary(provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> String? {
        let targets = targets(provider: provider, setup: setup)
        guard setup.enabled, targets.count > 1 else { return nil }
        let presences = targets.map { reports[$0]?.presence }
        let isChecking = mutating.contains(provider) || targets.contains { probing.contains($0) }
        if isChecking || presences.contains(where: { $0 == nil }) {
            return String(localized: "Checking folders", comment: "Agent plugin card summary while folder status checks run")
        }
        if presences.contains(.unknown) {
            return String(
                localized: "Some folders could not be checked",
                comment: "Agent plugin card summary when a folder status check failed"
            )
        }
        let installed = presences.filter { $0 == .present }.count
        return LocalizedPluralStrings.agentPluginInstalledFolders(installed: installed, total: targets.count)
    }

    // MARK: Card state

    func cardState(target: AgentPluginTarget, setup: AgentIntegrationSetup) -> AgentPluginCardState {
        let provider = target.provider
        let helper = helperPathResolver()
        let report = reports[target]
        let status = setup.enabled
            ? (report?.status ?? .notInstalled)
            : .notConfigured
        // Neutral "Checking" the moment a probe starts and until the first report
        // lands — keyed off the probe *having started* (not `probing`), so a cancelled
        // probe still reads as Checking rather than flashing the `.notInstalled`
        // fallback, and the next probe resolves it (#9).
        let isCheckingInitialStatus = setup.enabled
            && reports[target] == nil
            && (probeState[target] ?? .unprobed) != .unprobed

        return AgentPluginCardState(
            target: target,
            folderPath: folderPath(target, setup: setup),
            canForget: target.configHome.map { setup.additionalConfigHomes?.contains($0) == true } ?? false,
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
            guidance: actionGuidance[target],
            failureSummary: failureSummary(target: target, status: status),
            diagnostics: diagnostics(target: target),
            isBusy: mutating.contains(provider) || probing.contains { $0.provider == provider },
            inflightOp: inflightOp[target],
            isCheckingInitialStatus: isCheckingInitialStatus,
            statusLabel: isCheckingInitialStatus ? "Checking" : status.label
        )
    }

    /// Diagnostics come from a failed action first, then a failed probe — a
    /// non-zero `claude plugin list` attaches diagnostics to the status report,
    /// and the card must surface that stderr just as it does for a failed action.
    private func diagnostics(target: AgentPluginTarget) -> AgentPluginDiagnostics? {
        actionFailure(target)?.diagnostics ?? reports[target]?.diagnostics
    }

    private func actionFailure(_ target: AgentPluginTarget) -> AgentPluginActionOutcome? {
        #if DEBUG
            if debugSampleProviders.contains(target.provider) {
                return Self.sampleOutcome
            }
        #endif
        return actionFailures[target]
    }

    /// A failure summary is shown when either an action or a probe carried
    /// diagnostics. For a probe, the failing status' detail is the summary.
    private func failureSummary(target: AgentPluginTarget, status: AgentPluginStatus) -> String? {
        if let actionSummary = actionFailure(target).flatMap(Self.failureSummary) {
            return actionSummary
        }
        if reports[target]?.diagnostics != nil {
            return status.detail
        }
        return nil
    }

    // MARK: Confirmation

    func confirmation(
        for action: AgentPluginAction,
        target: AgentPluginTarget,
        setup: AgentIntegrationSetup
    ) -> AgentPluginConfirmation {
        runner.confirmation(for: action, provider: target.provider, setup: self.setup(for: target, from: setup))
    }

    // MARK: Async ops

    /// Read-only probe; safe to run automatically on enable (consent boundary).
    func refreshStatus(target: AgentPluginTarget, setup: AgentIntegrationSetup) async {
        let provider = target.provider
        let setup = self.setup(for: target, from: setup)
        guard setup.enabled else {
            reports[target] = nil
            actionFailures[target] = nil
            actionGuidance[target] = nil
            renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
            probing.remove(target)
            inflightOp[target] = nil
            probeState[target] = .unprobed
            return
        }
        guard !mutating.contains(provider), !probing.contains(target) else { return }
        probing.insert(target)
        inflightOp[target] = .probe
        // Set synchronously, before the first `await`: the card must read as
        // Checking from the instant the probe starts, and this must persist through
        // a cancellation (which returns below without ever reaching `.probed`).
        probeState[target] = .probing
        defer {
            probing.remove(target)
            inflightOp[target] = nil
        }

        renderedSourcePaths[provider] = renderedSourcePathProvider(provider)
        let report = await runner.status(provider: provider, setup: setup)
        // A cancelled probe leaves `probeState` at `.probing` on purpose: the card
        // keeps showing Checking (not a wrong terminal state) until a later probe
        // resolves it, rather than stranding on a stale fallback.
        guard !Task.isCancelled else { return }
        reports[target] = report
        probeState[target] = .probed
        // A fresh probe supersedes a prior action's transient state: a stale red
        // failure or reload guidance must not linger over a newly healthy status.
        actionFailures[target] = nil
        actionGuidance[target] = nil
    }

    func perform(
        action: AgentPluginAction,
        target: AgentPluginTarget,
        setup: AgentIntegrationSetup
    ) async {
        let provider = target.provider
        let setup = self.setup(for: target, from: setup)
        guard setup.enabled else { return }
        guard !mutating.contains(provider), !probing.contains(where: { $0.provider == provider }) else { return }
        mutating.insert(provider)
        inflightOp[target] = .mutation
        actionFailures[target] = nil
        actionGuidance[target] = nil
        defer {
            mutating.remove(provider)
            inflightOp[target] = nil
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
        reports[target] = AgentPluginStatusReport(status: outcome.status, diagnostics: outcome.diagnostics)
        // A mutation resolves the status too, so the card leaves the Checking state.
        probeState[target] = .probed
        if outcome.diagnostics != nil {
            actionFailures[target] = outcome
        } else if let guidance = outcome.guidance {
            actionGuidance[target] = guidance
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
        /// action-failure level `diagnostics(target:)` already reads, so
        /// the production `diagnosticsDisclosure` render path is exercised unchanged.
        /// Compiled out of release builds — regular users never see it (ADR-0012).
        func isSampleDiagnosticsInjected(for provider: AgentPluginProvider) -> Bool {
            debugSampleProviders.contains(provider)
        }

        func toggleSampleDiagnostics(for provider: AgentPluginProvider) {
            if debugSampleProviders.remove(provider) == nil {
                debugSampleProviders.insert(provider)
            }
        }

        fileprivate static var sampleOutcome: AgentPluginActionOutcome {
            AgentPluginActionOutcome(
                status: .needsRepair("Sample diagnostics (debug injection)"),
                guidance: nil,
                diagnostics: sampleDiagnostics
            )
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
