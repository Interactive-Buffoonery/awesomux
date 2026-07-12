import Foundation

// MARK: - AgentPluginStatus

/// The status vocabulary for the CLI-driven agent providers (Claude Code, Codex),
/// distinct from the file-drop `AgentIntegrationSettingsStatus` that OpenCode/Pi
/// use. These providers install through a provider CLI / app-server and carry a
/// trust model the file installer has no concept of, so they get their own
/// status type. See the install contract status table and ADR-0012.
///
/// The three failure channels the contract (§3) requires to stay distinct map to
/// distinct cases: a CLI that cannot host the plugin at all → `unsupported`; a
/// present-but-errored op → surfaced via `AgentPluginDiagnostics` on the action
/// outcome; a manifest/on-disk disagreement → `needsRepair`.
enum AgentPluginStatus: Equatable, Sendable {
    /// Provider integration is off in awesoMux. Do not probe or mutate provider
    /// state until the user opts in with the card toggle.
    case notConfigured
    /// Marketplace not registered / plugin never installed. Offer install.
    case notInstalled
    /// Installed, enabled, trusted (Codex), no errors. The healthy state.
    case enabled
    /// Installed but the user turned it off (Claude `disable` / Codex
    /// `enabled:false`). Respect the user; offer enable, never auto-flip.
    case disabled
    /// Installed but awaiting an explicit trust/approval step before it runs
    /// (Codex `trustStatus ∈ {untrusted, first-seen, changed}`). The associated
    /// value is the operator guidance ("Approve the hook in Codex").
    case needsReview(String)
    /// Manifest/config claims it is installed but on-disk reality disagrees
    /// (missing, modified, CLI error entry, configured-but-missing CODEX_HOME).
    /// The associated value is the repair guidance.
    case needsRepair(String)
    /// This CLI/version/policy cannot host the plugin at all (CLI absent,
    /// `--json`/`hooks/list` unsupported, `allow_managed_hooks_only`). The
    /// associated value is the reason. Do not auto-write; surface for manual
    /// handling.
    case unsupported(String)

    // MARK: Display

    var label: String {
        switch self {
        case .notConfigured: "Not enabled"
        case .notInstalled: "Not installed"
        case .enabled: "Enabled"
        case .disabled: "Off"
        case .needsReview: "Needs review"
        case .needsRepair: "Needs repair"
        case .unsupported:
            isExecutableNotFoundUnsupported ? "Executable not found" : "Unsupported"
        }
    }

    var detail: String {
        switch self {
        case .notConfigured:
            "Enable this integration before installing or managing its status plugin"
        case .notInstalled:
            "Install the awesoMux status plugin for this provider"
        case .enabled:
            "The status plugin is installed and active"
        case .disabled:
            "The status plugin is installed but turned off"
        case .needsReview(let guidance):
            guidance
        case .needsRepair(let guidance):
            guidance
        case .unsupported(let reason):
            reason
        }
    }

    private var isExecutableNotFoundUnsupported: Bool {
        guard case .unsupported(let reason) = self else { return false }
        let normalizedReason = reason.lowercased()
        return normalizedReason.contains("not found")
            && (normalizedReason.contains("cli") || normalizedReason.contains("executable"))
    }

    // MARK: Per-action gating

    /// Enable/Install is offered whenever the provider can host the plugin and it
    /// is not already enabled. `unsupported` cannot install; `enabled` is already
    /// on. `needsReview` does not offer enable — the plugin *is* enabled, it
    /// awaits trust, which is the user's out-of-band step.
    var allowsEnable: Bool {
        switch self {
        case .notInstalled, .disabled:
            true
        case .notConfigured, .enabled, .needsReview, .needsRepair, .unsupported:
            false
        }
    }

    /// Repair re-renders and re-installs in place. Offered when the on-disk state
    /// disagrees with the manifest, but never when the CLI cannot host the plugin.
    var allowsRepair: Bool {
        switch self {
        case .needsRepair:
            true
        case .notConfigured, .notInstalled, .enabled, .disabled, .needsReview, .unsupported:
            false
        }
    }

    /// Disable keeps the plugin installed but turns it off. Offered whenever the
    /// plugin is on (or awaiting trust while enabled).
    var allowsDisable: Bool {
        switch self {
        case .enabled, .needsReview:
            true
        case .notConfigured, .notInstalled, .disabled, .needsRepair, .unsupported:
            false
        }
    }

    /// Uninstall removes the plugin and de-registers the marketplace. Offered
    /// whenever anything is installed (anything other than not-installed /
    /// unsupported), so a broken install can always be cleaned up.
    var allowsUninstall: Bool {
        switch self {
        case .enabled, .disabled, .needsReview, .needsRepair:
            true
        case .notConfigured, .notInstalled, .unsupported:
            false
        }
    }
}

// MARK: - AgentPluginStatusReport

/// The result of a status probe: the mapped status plus optional diagnostics from
/// a failed probe sub-step (e.g. a present-but-errored `claude plugin list`).
struct AgentPluginStatusReport: Equatable, Sendable {
    var status: AgentPluginStatus
    var diagnostics: AgentPluginDiagnostics?
    /// True when status was read from the recorded install home but the live
    /// config-home field points elsewhere. Repair/Install use the live field, so
    /// the card can make that reconciliation path available without parsing note
    /// copy.
    var hasConfigHomeDrift: Bool
    /// Non-blocking advisory surfaced alongside the status, independent of it —
    /// e.g. status probes read the recorded config home while Repair/Install read
    /// the live field, so when those diverge the card must warn that actions and
    /// status target different homes. Rendered like the dist/ warning, not as the
    /// status detail.
    var note: String?

    init(
        status: AgentPluginStatus,
        diagnostics: AgentPluginDiagnostics? = nil,
        hasConfigHomeDrift: Bool = false,
        note: String? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.hasConfigHomeDrift = hasConfigHomeDrift
        self.note = note
    }
}

// MARK: - AgentPluginActionOutcome

/// The result of a mutating op (enable/install, repair, disable, uninstall): the
/// resulting status, optional post-mutation reload/review guidance, and optional
/// diagnostics when the op itself failed.
struct AgentPluginActionOutcome: Equatable, Sendable {
    var status: AgentPluginStatus
    /// Post-mutation advisory shown once after a successful mutation — e.g.
    /// "Run /reload-plugins or restart to pick this up" (decision 2). Distinct
    /// from `status.detail`, which describes the steady state.
    var guidance: String?
    var diagnostics: AgentPluginDiagnostics?

    init(
        status: AgentPluginStatus,
        guidance: String? = nil,
        diagnostics: AgentPluginDiagnostics? = nil
    ) {
        self.status = status
        self.guidance = guidance
        self.diagnostics = diagnostics
    }
}

extension AgentPluginActionOutcome {
    func asRepairableFailure(repairGuidance: String) -> AgentPluginActionOutcome {
        AgentPluginActionOutcome(
            status: .needsRepair(repairGuidance),
            guidance: guidance,
            diagnostics: diagnostics
        )
    }
}
