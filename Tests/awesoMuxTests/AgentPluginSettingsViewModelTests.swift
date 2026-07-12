import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent plugin settings view model")
@MainActor
struct AgentPluginSettingsViewModelTests {
    // MARK: - Card state derivation

    @Test("a provider that is not opted in exposes no mutating actions")
    func notOptedInProviderHasNoActions() async {
        let runner = StubAgentPluginRunner()
        let vm = Self.viewModel(runner: runner)

        let state = vm.cardState(provider: .claudeCode, setup: AgentIntegrationSetup(enabled: false))
        #expect(state.status == .notConfigured)
        #expect(state.binaryPlaceholder == "claude")
        #expect(!state.allowsEnable)
        #expect(!state.allowsRepair)
        #expect(!state.allowsDisable)
        #expect(!state.allowsUninstall)
        // No probe runs for a disabled provider (consent boundary).
        #expect(runner.statusCalls.isEmpty)
    }

    @Test("card state reflects the latest probed status")
    func cardStateReflectsProbe() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(status: .enabled)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.status == .enabled)
        #expect(runner.statusCalls.count == 1)
    }

    @Test("missing executable statuses use a specific badge label")
    func missingExecutableStatusLabel() async {
        let runner = StubAgentPluginRunner()
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        runner.statusResult = AgentPluginStatusReport(
            status: .unsupported("The claude CLI was not found at /tmp/claude")
        )
        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        var state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.statusLabel == "Executable not found")
        #expect(state.status.detail == "The claude CLI was not found at /tmp/claude")

        runner.statusResult = AgentPluginStatusReport(
            status: .unsupported("The codex CLI was not found at /tmp/codex")
        )
        await vm.refreshStatus(provider: .codex, setup: setup)
        state = vm.cardState(provider: .codex, setup: setup)
        #expect(state.statusLabel == "Executable not found")
        #expect(state.status.detail == "The codex CLI was not found at /tmp/codex")
    }

    @Test("other unsupported statuses keep the generic badge label")
    func nonExecutableUnsupportedStatusLabel() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(
            status: .unsupported("This claude version does not support plugin list --json")
        )
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)

        #expect(state.statusLabel == "Unsupported")
    }

    @Test("per-status action gating maps onto the card")
    func actionGating() async {
        let runner = StubAgentPluginRunner()
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        runner.statusResult = AgentPluginStatusReport(status: .notInstalled)
        await vm.refreshStatus(provider: .codex, setup: setup)
        var state = vm.cardState(provider: .codex, setup: setup)
        #expect(state.allowsEnable)
        #expect(!state.allowsDisable)
        #expect(!state.allowsUninstall)

        runner.statusResult = AgentPluginStatusReport(status: .needsReview("approve it"))
        await vm.refreshStatus(provider: .codex, setup: setup)
        state = vm.cardState(provider: .codex, setup: setup)
        #expect(!state.allowsEnable)
        #expect(!state.allowsRepair)
        #expect(state.allowsDisable)
        #expect(state.allowsUninstall)
    }

    @Test("Codex home drift allows Repair while awaiting review")
    func codexHomeDriftAllowsRepairWhileNeedsReview() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(
            status: .needsReview("Approve the awesoMux hook in Codex to let it run"),
            hasConfigHomeDrift: true,
            note: "Actions target the recorded home /tmp/old; the CODEX_HOME field now points at /tmp/new. Repair to move the install, or restore the field to keep using the recorded home."
        )
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true, configHome: "/tmp/new")

        await vm.refreshStatus(provider: .codex, setup: setup)
        let state = vm.cardState(provider: .codex, setup: setup)

        #expect(state.status == .needsReview("Approve the awesoMux hook in Codex to let it run"))
        #expect(state.note != nil)
        #expect(state.allowsRepair)
        #expect(state.allowsDisable)
        #expect(state.allowsUninstall)
    }

    @Test("non-drift Needs review keeps Repair unavailable")
    func nonDriftNeedsReviewKeepsRepairUnavailable() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(status: .needsReview("approve it"))
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.refreshStatus(provider: .codex, setup: setup)
        let state = vm.cardState(provider: .codex, setup: setup)

        #expect(!state.allowsRepair)
        #expect(state.allowsDisable)
        #expect(state.allowsUninstall)
    }

    // MARK: - Probe lifecycle (#9)

    @Test("pre-probe an enabled provider reads as Checking, not Not installed")
    func preProbeShowsCheckingNotNotInstalled() async {
        let runner = StubAgentPluginRunner()
        runner.statusDelay = .milliseconds(100)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        let task = Task { await vm.refreshStatus(provider: .codex, setup: setup) }
        await Task.yield()
        // The instant the probe starts, before any report lands, the card must show
        // the neutral Checking state rather than flashing the Not-installed fallback.
        let checking = vm.cardState(provider: .codex, setup: setup)
        #expect(checking.isCheckingInitialStatus)
        #expect(checking.statusLabel == "Checking")

        await task.value
    }

    @Test("a cancelled probe does not strand on Checking; the next probe resolves it")
    func cancelledProbeDoesNotStrand() async {
        let runner = StubAgentPluginRunner()
        runner.statusDelay = .seconds(5)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        let probe = Task { await vm.refreshStatus(provider: .codex, setup: setup) }
        await Task.yield()
        #expect(vm.cardState(provider: .codex, setup: setup).isCheckingInitialStatus)

        // Cancel the in-flight probe. It returns before assigning a report, so the
        // card stays on Checking (not a wrong terminal state) rather than showing a
        // stale Not-installed — the strand the hasProbed/probing flag prevents.
        probe.cancel()
        await probe.value
        let afterCancel = vm.cardState(provider: .codex, setup: setup)
        #expect(afterCancel.isCheckingInitialStatus)
        #expect(afterCancel.statusLabel == "Checking")
        #expect(!afterCancel.isBusy)

        // A fresh probe resolves the state to the real status.
        runner.statusDelay = nil
        runner.statusResult = AgentPluginStatusReport(status: .enabled)
        await vm.refreshStatus(provider: .codex, setup: setup)
        let resolved = vm.cardState(provider: .codex, setup: setup)
        #expect(!resolved.isCheckingInitialStatus)
        #expect(resolved.status == .enabled)
    }

    // MARK: - Op kind + cancel affordance (#8)

    @Test("a probe in flight is cancellable; a mutation is not")
    func onlyProbesAreCancellable() async {
        let runner = StubAgentPluginRunner()
        runner.statusDelay = .milliseconds(100)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        let probe = Task { await vm.refreshStatus(provider: .codex, setup: setup) }
        await Task.yield()
        let probing = vm.cardState(provider: .codex, setup: setup)
        #expect(probing.inflightOp == .probe)
        #expect(probing.canCancel)
        await probe.value

        // A mutation is busy but not cancellable — the CLI op runs to completion.
        runner.actionDelay = .milliseconds(100)
        let mutate = Task { await vm.perform(action: .uninstall, provider: .codex, setup: setup) }
        await Task.yield()
        let mutating = vm.cardState(provider: .codex, setup: setup)
        #expect(mutating.inflightOp == .mutation)
        #expect(!mutating.canCancel)
        await mutate.value
        #expect(vm.cardState(provider: .codex, setup: setup).inflightOp == nil)
    }

    // MARK: - Check status (#6)

    @Test("check status re-probes an idle enabled provider")
    func checkStatusReProbes() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(status: .needsReview("approve it"))
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.refreshStatus(provider: .codex, setup: setup)
        #expect(vm.cardState(provider: .codex, setup: setup).status == .needsReview("approve it"))

        // Out-of-band approval clears the review; a manual re-probe picks it up.
        runner.statusResult = AgentPluginStatusReport(status: .enabled)
        await vm.refreshStatus(provider: .codex, setup: setup)
        #expect(vm.cardState(provider: .codex, setup: setup).status == .enabled)
        #expect(runner.statusCalls == [.codex, .codex])
    }

    // MARK: - Confirmation

    @Test("confirmation payload names the executable, config target, and intent")
    func confirmationNamesTargets() {
        let runner = StubAgentPluginRunner()
        runner.confirmationResult = AgentPluginConfirmation(
            action: .enableOrInstall,
            title: "Install the Claude Code status plugin",
            executablePath: "claude",
            configTargets: ["~/.claude/settings.json"],
            commandLines: ["claude plugin install awesomux-claude-status@awesomux-claude --scope user"]
        )
        let vm = Self.viewModel(runner: runner)

        let confirmation = vm.confirmation(for: .enableOrInstall, provider: .claudeCode, setup: AgentIntegrationSetup(enabled: true))
        #expect(confirmation.executablePath == "claude")
        #expect(confirmation.configTargets == ["~/.claude/settings.json"])
        #expect(confirmation.commandLines.first?.contains("--scope user") == true)
    }

    // MARK: - Dist warning

    @Test("dist warning appears only when the helper is a development bundle")
    func distWarningSurfacesForDevBundle() async {
        let runner = StubAgentPluginRunner()
        let setup = AgentIntegrationSetup(enabled: true)

        let dev = Self.viewModel(
            runner: runner,
            helper: AgentHookHelperPath(path: "/work/dist/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: true)
        )
        #expect(dev.cardState(provider: .claudeCode, setup: setup).distWarning != nil)

        let release = Self.viewModel(
            runner: runner,
            helper: AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)
        )
        #expect(release.cardState(provider: .claudeCode, setup: setup).distWarning == nil)
    }

    // MARK: - Guidance and failure

    @Test("a successful mutation surfaces reload/review guidance")
    func successfulMutationSurfacesGuidance() async {
        let runner = StubAgentPluginRunner()
        runner.actionResult = AgentPluginActionOutcome(
            status: .enabled,
            guidance: "Run /reload-plugins or restart to pick this up"
        )
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.perform(action: .enableOrInstall, provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.status == .enabled)
        #expect(state.guidance == "Run /reload-plugins or restart to pick this up")
        #expect(state.failureSummary == nil)
    }

    @Test("a failed mutation surfaces a summary plus expandable diagnostics")
    func failedMutationSurfacesDiagnostics() async {
        let runner = StubAgentPluginRunner()
        let diagnostics = AgentPluginDiagnostics(
            executablePath: "/opt/homebrew/bin/claude",
            args: ["plugin", "install"],
            exitCode: 1,
            rawStdout: "",
            rawStderr: "boom",
            summary: "install failed",
            homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )
        runner.actionResult = AgentPluginActionOutcome(
            status: .needsRepair("The command failed; see diagnostics"),
            diagnostics: diagnostics
        )
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.perform(action: .enableOrInstall, provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.failureSummary != nil)
        #expect(state.diagnostics == diagnostics)
        // Failure suppresses the success-guidance channel.
        #expect(state.guidance == nil)
    }

    @Test("a failed probe surfaces its diagnostics on the card")
    func failedProbeSurfacesDiagnostics() async {
        let runner = StubAgentPluginRunner()
        let diagnostics = AgentPluginDiagnostics(
            executablePath: "/opt/homebrew/bin/claude",
            args: ["plugin", "list", "--json"],
            exitCode: 2,
            rawStdout: "",
            rawStderr: "list failed",
            summary: "probe failed",
            homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )
        runner.statusResult = AgentPluginStatusReport(
            status: .needsRepair("claude plugin list failed; re-install may be required"),
            diagnostics: diagnostics
        )
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        // A failed probe is a failed outcome: summary + expandable diagnostics.
        #expect(state.diagnostics == diagnostics)
        #expect(state.failureSummary != nil)
    }

    @Test("a fresh probe clears stale action failure state")
    func freshProbeClearsStaleFailure() async {
        let runner = StubAgentPluginRunner()
        let setup = AgentIntegrationSetup(enabled: true)
        let vm = Self.viewModel(runner: runner)

        // A prior action failed, leaving a red summary + diagnostics on the card.
        runner.actionResult = AgentPluginActionOutcome(
            status: .needsRepair("boom"),
            diagnostics: AgentPluginDiagnostics(
                executablePath: "/bin/claude", args: [], exitCode: 1,
                rawStdout: "", rawStderr: "boom", summary: "x",
                homeDirectory: URL(fileURLWithPath: "/Users/nobody")
            )
        )
        await vm.perform(action: .enableOrInstall, provider: .claudeCode, setup: setup)
        #expect(vm.cardState(provider: .claudeCode, setup: setup).diagnostics != nil)

        // A later healthy probe must supersede the stale failure.
        runner.statusResult = AgentPluginStatusReport(status: .enabled)
        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.status == .enabled)
        #expect(state.diagnostics == nil)
        #expect(state.failureSummary == nil)
    }

    @Test("perform dispatches the requested action to the runner")
    func performDispatchesAction() async {
        let runner = StubAgentPluginRunner()
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        await vm.perform(action: .uninstall, provider: .codex, setup: setup)
        #expect(runner.actionCalls == [.uninstall])
    }

    @Test("refresh status sets busy and blocks overlapping work")
    func refreshSetsBusyAndBlocksOverlap() async {
        let runner = StubAgentPluginRunner()
        runner.statusDelay = .milliseconds(100)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)

        let task = Task { await vm.refreshStatus(provider: .codex, setup: setup) }
        await Task.yield()
        let checking = vm.cardState(provider: .codex, setup: setup)
        #expect(checking.isBusy)
        #expect(checking.isCheckingInitialStatus)
        #expect(checking.statusLabel == "Checking")

        await vm.perform(action: .uninstall, provider: .codex, setup: setup)
        #expect(runner.actionCalls.isEmpty)

        await task.value
        #expect(!vm.cardState(provider: .codex, setup: setup).isBusy)
        #expect(runner.statusCalls == [.codex])
    }

    @Test("perform does nothing when setup is disabled")
    func performDoesNothingWhenDisabled() async {
        let runner = StubAgentPluginRunner()
        let vm = Self.viewModel(runner: runner)

        await vm.perform(action: .enableOrInstall, provider: .claudeCode, setup: AgentIntegrationSetup(enabled: false))

        #expect(runner.actionCalls.isEmpty)
    }

    @Test("card state reuses cached rendered source path")
    func cardStateReusesCachedRenderedSourcePath() async {
        let runner = StubAgentPluginRunner()
        var calls = 0
        let vm = Self.viewModel(runner: runner) { provider in
            calls += 1
            return "/rendered/\(provider)"
        }
        let setup = AgentIntegrationSetup(enabled: true)

        _ = vm.cardState(provider: .claudeCode, setup: setup)
        _ = vm.cardState(provider: .claudeCode, setup: setup)
        _ = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(calls == AgentPluginProvider.allCases.count)

        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        let state = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(state.renderedSourcePath == "/rendered/claudeCode")
        #expect(calls == AgentPluginProvider.allCases.count + 1)
    }

    // MARK: - DEBUG-only sample diagnostics injection

    #if DEBUG
    @Test("injecting sample diagnostics surfaces them through the real card gate")
    func injectedSampleShowsDiagnostics() async {
        let runner = StubAgentPluginRunner()
        runner.statusResult = AgentPluginStatusReport(status: .enabled)
        let vm = Self.viewModel(runner: runner)
        let setup = AgentIntegrationSetup(enabled: true)
        await vm.refreshStatus(provider: .claudeCode, setup: setup)
        #expect(vm.cardState(provider: .claudeCode, setup: setup).diagnostics == nil)

        vm.toggleSampleDiagnostics(for: .claudeCode)
        #expect(vm.isSampleDiagnosticsInjected(for: .claudeCode))
        let injected = vm.cardState(provider: .claudeCode, setup: setup)
        #expect(injected.diagnostics != nil)
        // Injection is per-provider: the other provider is untouched.
        #expect(!vm.isSampleDiagnosticsInjected(for: .codex))
        #expect(vm.cardState(provider: .codex, setup: setup).diagnostics == nil)
        // The sample exercises the length cap the disclosure relies on.
        #expect(injected.diagnostics?.stderr.contains("[truncated]") == true)

        vm.toggleSampleDiagnostics(for: .claudeCode)
        #expect(!vm.isSampleDiagnosticsInjected(for: .claudeCode))
        #expect(vm.cardState(provider: .claudeCode, setup: setup).diagnostics == nil)
    }
    #endif

    // MARK: - Fixtures

    static func viewModel(
        runner: StubAgentPluginRunner,
        helper: AgentHookHelperPath? = AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false),
        renderedSourcePathProvider: @escaping (AgentPluginProvider) -> String? = { _ in nil }
    ) -> AgentPluginSettingsViewModel {
        AgentPluginSettingsViewModel(
            runner: runner,
            helperPathResolver: { helper },
            renderedSourcePathProvider: renderedSourcePathProvider
        )
    }
}

// MARK: - StubAgentPluginRunner

final class StubAgentPluginRunner: AgentPluginRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _statusResult = AgentPluginStatusReport(status: .notInstalled)
    private var _actionResult = AgentPluginActionOutcome(status: .enabled)
    private var _confirmationResult = AgentPluginConfirmation(
        action: .enableOrInstall, title: "", executablePath: "/bin/x",
        configTargets: [], commandLines: []
    )
    private var _statusDelay: Duration?
    private var _actionDelay: Duration?
    private var _statusCalls: [AgentPluginProvider] = []
    private var _actionCalls: [AgentPluginAction] = []

    var statusResult: AgentPluginStatusReport {
        get { lock.withLock { _statusResult } }
        set { lock.withLock { _statusResult = newValue } }
    }
    var actionResult: AgentPluginActionOutcome {
        get { lock.withLock { _actionResult } }
        set { lock.withLock { _actionResult = newValue } }
    }
    var confirmationResult: AgentPluginConfirmation {
        get { lock.withLock { _confirmationResult } }
        set { lock.withLock { _confirmationResult = newValue } }
    }
    var statusDelay: Duration? {
        get { lock.withLock { _statusDelay } }
        set { lock.withLock { _statusDelay = newValue } }
    }
    var actionDelay: Duration? {
        get { lock.withLock { _actionDelay } }
        set { lock.withLock { _actionDelay = newValue } }
    }
    var statusCalls: [AgentPluginProvider] { lock.withLock { _statusCalls } }
    var actionCalls: [AgentPluginAction] { lock.withLock { _actionCalls } }

    func status(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        let delay = lock.withLock { () -> Duration? in
            _statusCalls.append(provider)
            return _statusDelay
        }
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return lock.withLock { _statusResult }
    }

    private func recordAction(_ action: AgentPluginAction) async -> AgentPluginActionOutcome {
        let delay = lock.withLock { () -> Duration? in
            _actionCalls.append(action)
            return _actionDelay
        }
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return lock.withLock { _actionResult }
    }

    func enableOrInstall(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        await recordAction(.enableOrInstall)
    }

    func repair(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        await recordAction(.repair)
    }

    func disable(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        await recordAction(.disable)
    }

    func uninstall(provider: AgentPluginProvider, setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        await recordAction(.uninstall)
    }

    func confirmation(for action: AgentPluginAction, provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> AgentPluginConfirmation {
        lock.withLock { _confirmationResult }
    }
}
