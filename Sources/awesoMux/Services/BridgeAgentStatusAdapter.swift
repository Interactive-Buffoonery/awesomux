import AwesoMuxCore
import Foundation

/// Adapts validated `awesomux-bridge-v1` frames into the app's existing local
/// agent read model. This is the read-model half of C2's frame-sink seam:
/// `frameSink` matches `BridgeConnectionSupervisor.FrameSink`, so D4 can hand
/// this adapter the supervisor's post-handshake frames for a session's
/// generation without D4 or the supervisor knowing anything about the read
/// model. It handles agent-status, pane-rename, and handoff-notify messages.
///
/// Design intent — mirror the LOCAL channel, do not re-derive it. `agent-status`
/// and `pane-rename` are reconstructed into the very same `AgentRuntimeEvent`
/// the local `awesomux-agent-v1` file drop produces, then handed to the same
/// apply path (`applyEvent`). That is deliberate: `(eventID, ts)` dedupe,
/// staleness (equal-or-older dropped, future `ts` clamped to now), the rename
/// empty-vs-non-empty-vs-absent contract, and the `SessionUpdate` /
/// `SessionAgentRollup` mapping ALL live in the one shared
/// `AgentRuntimeEventReducer` behind that path — a second copy here would be a
/// place for the two channels to silently diverge. The adapter's own job is the
/// narrow bridge-only concerns: reconstructing the event from the flat frame,
/// running consent **per-event at apply time against a live settings read**
/// (never a spawn-time snapshot — a provider disabled after attach must drop the
/// next frame), and surfacing a `handoff-notify` without ever touching the
/// filesystem.
struct BridgeAgentStatusAdapter: Sendable {
    /// Live consent read, evaluated once per applied event. D4 wires this to
    /// the current `appSettingsStore.agentIntegrations.value`, exactly like the
    /// local surface's `applyAgentRuntimeEvent`. MainActor-isolated and
    /// synchronous so the read and the store mutation below happen in ONE hop
    /// with no suspension between them — see `applyOnMain`.
    private let consent: @MainActor @Sendable () -> AgentRuntimeConsent
    /// The shared local apply path. D4 resolves `session` (the frame's
    /// correlation id, a `TerminalSessionID` string) to a store + pane and calls
    /// `SessionStore.applyAgentRuntimeEvent` — the same reducer the file drop
    /// uses, which is why dedupe/staleness/mapping are not re-implemented here.
    private let applyEvent: @MainActor @Sendable (_ event: AgentRuntimeEvent, _ session: String) -> Void
    /// Surfaces a `handoff-notify` (a remote inbox path + advisory metadata) to
    /// the pane. The bridge only NOTIFIES; the actual byte transfer and any
    /// filesystem access are INT-699's, out of scope here.
    private let surfaceHandoff: @MainActor @Sendable (_ notify: HandoffNotify, _ session: String) -> Void

    init(
        consent: @escaping @MainActor @Sendable () -> AgentRuntimeConsent,
        applyEvent: @escaping @MainActor @Sendable (_ event: AgentRuntimeEvent, _ session: String) -> Void,
        surfaceHandoff: @escaping @MainActor @Sendable (_ notify: HandoffNotify, _ session: String) -> Void
    ) {
        self.consent = consent
        self.applyEvent = applyEvent
        self.surfaceHandoff = surfaceHandoff
    }

    /// The C2 seam. `generation` correlates a permission-decision reply to the
    /// connection that issued its request; the read-model frame types this
    /// adapter handles do not reply on the connection, so it is intentionally
    /// dropped here. Permission-lifecycle frames ride the same seam but are a
    /// different component's responsibility (see `apply`).
    var frameSink: BridgeConnectionSupervisor.FrameSink {
        { envelope, _ in await apply(envelope) }
    }

    /// Core translation, called by `frameSink` (and directly by tests, which
    /// cannot mint a `BridgeConnectionActor.Generation`). Hops to the MainActor
    /// once; all read-model work happens in `applyOnMain`.
    func apply(_ envelope: BridgeEnvelope) async {
        await MainActor.run { applyOnMain(envelope) }
    }

    /// Every envelope here is already validated by `BridgeEnvelope.parse` — the
    /// A0 UnicodeHygiene fence on `title`/`path`/`name` runs there, so a hostile
    /// free-text field never becomes an envelope in the first place and the
    /// adapter deliberately does NOT re-validate.
    ///
    /// Consent and application run back-to-back with no `await` between them, so
    /// no other MainActor work can interleave a settings change into the gap —
    /// the same atomicity the local surface's synchronous `applyAgentRuntimeEvent`
    /// has. (An `async` consent read followed by an `async` apply would open a
    /// suspension window where a just-revoked provider's frame could still land.)
    @MainActor
    private func applyOnMain(_ envelope: BridgeEnvelope) {
        switch envelope.message {
        case .agentStatus(let status):
            applyRuntimeEvent(runtimeEvent(from: status, envelope: envelope), session: envelope.session)

        case .paneRename(let title):
            applyRuntimeEvent(renameEvent(title: title, envelope: envelope), session: envelope.session)

        case .handoffNotify(let notify):
            // Path already passed `validatedRemotePath` (absolute, no
            // NUL/bidi/zero-width, length-bounded) at parse. Surface only —
            // never open/execute/read it.
            surfaceHandoff(notify, envelope.session)

        case .permissionRequest, .permissionDecision, .permissionResolved:
            // Permission lifecycle is a separate seam (its own request map + UI);
            // this adapter is strictly the agent-status/rename/handoff read-model
            // translator. Dropping here is correct, not a gap.
            break
        }
    }

    @MainActor
    private func applyRuntimeEvent(_ event: AgentRuntimeEvent, session: String) {
        // Live, per-event, at apply time — identical to the local surface's
        // `applyAgentRuntimeEvent`. A file-drop provider (opencode/pi) disabled
        // in settings AFTER attach drops the NEXT frame precisely because this
        // reads current settings rather than a captured set.
        guard consent().allows(event) else { return }
        applyEvent(event, session)
    }

    /// Reconstructs the local-channel event from the bridge's flat `agent-status`
    /// payload. The bridge omits the local `state` field by design; `execution`
    /// and `attentionReason` are sent explicitly and `AgentState` is only ever a
    /// combined projection of those two, so nothing is lost. `title`/
    /// `documentPath` are agent-status-irrelevant (rename and file handoff are
    /// their own frame types). `ts` is the envelope's; the reducer's staleness
    /// guard clamps a future value to now.
    private func runtimeEvent(from status: AgentStatus, envelope: BridgeEnvelope) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: status.source,
            kind: status.kind,
            executionState: status.execution,
            attentionReason: status.attentionReason,
            state: nil,
            phase: status.phase,
            eventID: status.eventID,
            providerSessionID: status.providerSessionID,
            title: nil,
            documentPath: nil,
            timestamp: Date(timeIntervalSince1970: envelope.ts)
        )
    }

    /// `pane-rename` reuses the local `phase == .rename` path verbatim: the
    /// reducer resolves an empty title to a reset and a non-empty one to a pin,
    /// both after the shared dedupe/staleness guards. An ABSENT title never
    /// reaches here — `BridgeEnvelope.parse` drops a `pane-rename` frame with no
    /// `title`, so the "absent → drop" contract is enforced upstream at parse.
    ///
    /// `.unknown` source: a rename is not a file-drop-provider signal, so it must
    /// clear consent unconditionally, and `AgentRuntimeConsent.allows` returns
    /// true for `.unknown` + nil kind. `envelope.id` (the per-message UUID) is the
    /// dedupe key, matching the local channel's per-event `eventID`.
    private func renameEvent(title: String, envelope: BridgeEnvelope) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .unknown,
            phase: .rename,
            eventID: envelope.id,
            title: title,
            timestamp: Date(timeIntervalSince1970: envelope.ts)
        )
    }
}
