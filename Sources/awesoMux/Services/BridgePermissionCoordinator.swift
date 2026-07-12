import AppKit
import AwesoMuxCore
import Foundation
import Observation

/// The app-side twin of the `permission-request` lifecycle for ONE remote
/// attach (spec §"Permission lifecycle", §"Accessibility contract"). It wraps
/// the A4 invariant core (`BridgePendingRequestMap`) — it does NOT reimplement
/// the cap, the first-terminal-event-wins atomicity, or the deadline-wins
/// relabel — and layers the policy the spec makes app-authoritative on top:
///
///  - **Own per-connection cap (4).** A request past the cap is answered with an
///    immediate `deny` decision frame and never enqueued in UI. The helper's map
///    is untrusted; the app enforces its own cap independently (spec: "the app's
///    own per-connection cap denies … without enqueueing UI even when the
///    helper's map claims otherwise").
///  - **Authoritative local deadline** `min(expiresAt, now + 120s)`. The app
///    twin is authoritative because the helper's per-*process* cap/timeout can't
///    span processes (B2 caveat) — a helper that never sends
///    `permission-resolved` still can't leave a zombie prompt.
///  - **FIFO one-at-a-time presentation.** A single active prompt; the rest wait
///    in arrival order. Queued requests keep their own clocks — one can expire
///    before it ever presents, which advances the FIFO and announces the
///    timeout.
///  - **Never-send-after-resolved.** Resolution (peek → `resolve`, single
///    authoritative map, all synchronous on this MainActor) precedes any frame
///    write, so a late decision for an already-resolved id is never written.
///  - **`scope: session` grants** keyed to the exact `{tool, target}` pair *and*
///    the connection generation. A re-mint (new generation) evicts them; a
///    matching grant answers a request immediately with no UI.
///  - **Generation-tagged decision writes.** Every decision goes out through the
///    connection actor with the request's generation (C1), so a late decision
///    can't land on a replaced fd. Connection loss default-denies pendings
///    *locally* and writes nothing to the dead connection.
///
/// **One authoritative instance, serialized on the MainActor.** The A4 map is a
/// value type; its atomicity holds only within a single instance behind a
/// serialization boundary. This class is `@MainActor`, so every map mutation,
/// FIFO update, grant read, and observable-state publish runs on one actor with
/// no interleaving — the same boundary the read-model adapter (E2) uses. Frame
/// writes are the one place we touch another isolation domain: state mutation
/// completes *synchronously* first, then `sendDecision` (a fire-and-forget hop
/// into the connection actor) runs, so an `await`-driven reentrancy during the
/// send can never observe a half-resolved map.
///
/// Exposes `frameSink`/`connectionLostSink` matching C2's seams (mirrors E2);
/// D4 fans the supervisor's post-handshake frames to both this coordinator and
/// the read-model adapter. This coordinator owns the permission-lifecycle
/// frames; E2 owns agent-status/rename/handoff and drops permission frames.
@MainActor
@Observable
final class BridgePermissionCoordinator {

    /// The prompt the banner renders — the head of the FIFO queue, or `nil` when
    /// nothing is pending. Only the display/authorization-relevant fields; the
    /// routing metadata (generation, deadline) stays private.
    struct ActivePrompt: Equatable, Identifiable {
        let id: String
        let tool: String
        let target: String
        let summary: String?
    }

    // MARK: - Observable presentation state (read by the banner)

    private(set) var activePrompt: ActivePrompt?
    /// Number of prompts waiting *behind* the active one. The banner shows this
    /// as a badge and exposes it to assistive tech via the stringsdict plural.
    private(set) var queuedCount: Int = 0
    /// Bumped by `requestFocus()` — the banner observes it to move focus to the
    /// active prompt (the single deliberate, user-initiated focus move). A token
    /// rather than a `Bool` so repeated requests each re-fire even if the banner
    /// never cleared the prior one.
    private(set) var focusRequestToken: Int = 0
    /// True only while the user has deliberately focused the presented prompt
    /// via `requestFocus()` (the `focusPermissionPrompt` palette command) AND
    /// that same prompt is still the one presented. Gates the keyboard-Allow
    /// mappings in `BridgePermissionPromptKey` (USER RULING, INT-698
    /// addendum) — independently of SwiftUI's own `@FocusState`, which this
    /// coordinator has no guarantee resets cleanly across the banner's
    /// disappear/reappear cycle between prompts (repo memory: stale
    /// transient state kept alive by a widened gate). Narrowest-correct
    /// clearing, in two places: `publish()` clears it the instant the
    /// presented id changes for ANY reason (resolve, advance, teardown,
    /// connection loss, generation change all funnel through it), and
    /// `clearPromptFocus()` clears it when the SAME prompt is still presented
    /// but SwiftUI focus itself moved back to the terminal.
    private(set) var promptFocused: Bool = false

    // MARK: - Injected collaborators / bookkeeping (not observed)

    @ObservationIgnored private let expectedToken: String
    @ObservationIgnored private let expectedSession: String
    @ObservationIgnored private let paneTitle: @MainActor @Sendable () -> String
    @ObservationIgnored private let paneDescriptor: @MainActor @Sendable () -> String?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Fire-and-forget decision write. Synchronous by design so a write stays
    /// inside this MainActor's atomic section (the async hop into the connection
    /// actor lives in the production closure, not here). Generation-tagged per C1.
    @ObservationIgnored private let sendDecision:
        @MainActor @Sendable (BridgeEnvelope, BridgeConnectionActor.Generation) -> Void
    @ObservationIgnored private let announce:
        @MainActor @Sendable (String, NSAccessibilityPriorityLevel) -> Void
    /// Live read of the agent-integrations master switch — the same gate
    /// `shouldRunPreflight` consults at attach time, but read PER REQUEST here
    /// so flipping the switch off mid-session actually stops the permission
    /// surface (review finding: the read-model adapter already re-reads consent
    /// live, but permission prompts kept appearing after the toggle went off).
    /// A request that arrives while the switch is off is fail-closed denied
    /// with no UI — the agent unblocks deterministically rather than hanging.
    @ObservationIgnored private let permissionEnabled: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let pendingCountChanged: @MainActor @Sendable (Int, Int) -> Void
    /// Injected so a test can drive expiry deterministically instead of racing a
    /// real timer; defaults to `Task.sleep`. Called with the seconds until the
    /// nearest deadline.
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void

    /// The A4 invariant core — cap, duplicate detection, first-terminal-event
    /// atomicity, deadline-wins relabel. Wrapped, never reimplemented.
    @ObservationIgnored private var pending = BridgePendingRequestMap()
    /// FIFO arrival order of pending ids. `first` is the presented prompt.
    @ObservationIgnored private var order: [String] = []
    /// Per-id routing/display metadata the A4 `Entry` doesn't carry (generation
    /// for the reply, `summary` for display, the resolved local deadline for
    /// scheduling). Kept in lockstep with the map: every add/remove touches both,
    /// always gated on the map's own outcome so it can't diverge.
    @ObservationIgnored private var context: [String: PromptContext] = [:]
    /// Active `{tool, target, generation}` session grants. A grant answers a
    /// matching request with no UI; it dies when its generation is superseded.
    @ObservationIgnored private var sessionGrants: Set<SessionGrant> = []
    /// The generation of the most recently seen request. A different generation
    /// is a re-mint and evicts every grant that isn't from it.
    @ObservationIgnored private var latestGeneration: BridgeConnectionActor.Generation?
    /// Single timer that fires at the nearest pending deadline. Rescheduled on
    /// every admit/resolution; there's at most one because expiry is a sweep of
    /// all overdue entries, not a per-id alarm.
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// When the last connection-loss cancellation was ANNOUNCED. A flapping
    /// bridge (die → reconnect → die) drains and default-denies its pendings
    /// every cycle, which is correct — but announcing "permission request
    /// cancelled" on every cycle machine-guns VoiceOver (review finding). The
    /// drain/deny still runs each time; only the spoken announcement is
    /// coalesced within `connectionLostAnnouncementDebounce`.
    @ObservationIgnored private var lastConnectionLostAnnouncedAt: Date?
    private static let connectionLostAnnouncementDebounce: TimeInterval = 3
    /// After FIFO advances, ignore user decisions until this instant so a
    /// double-click cannot authorize the *next* prompt (review finding).
    @ObservationIgnored private var decisionsDisarmedUntil: Date = .distantPast
    /// The prompt id the user deliberately focused via `requestFocus`. Keyboard
    /// Allow/Deny bind to this id — never the live head — so a late key cannot
    /// authorize a successor that slid into place after focus was granted.
    @ObservationIgnored private var focusedPromptID: String?

    static var connectionLostAnnouncementDebounceForTesting: TimeInterval {
        connectionLostAnnouncementDebounce
    }

    init(
        expectedToken: String,
        expectedSession: String,
        paneTitle: @escaping @MainActor @Sendable () -> String,
        paneDescriptor: @escaping @MainActor @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date = Date.init,
        sendDecision: @escaping @MainActor @Sendable (BridgeEnvelope, BridgeConnectionActor.Generation) -> Void,
        announce: @escaping @MainActor @Sendable (String, NSAccessibilityPriorityLevel) -> Void
            = { TerminalAccessibilityAnnouncer.announce($0, priority: $1) },
        permissionEnabled: @escaping @MainActor @Sendable () -> Bool = { true },
        pendingCountChanged: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        }
    ) {
        self.expectedToken = expectedToken
        self.expectedSession = expectedSession
        self.paneTitle = paneTitle
        self.paneDescriptor = paneDescriptor
        self.now = now
        self.sendDecision = sendDecision
        self.announce = announce
        self.permissionEnabled = permissionEnabled
        self.pendingCountChanged = pendingCountChanged
        self.sleep = sleep
    }

    deinit {
        expiryTask?.cancel()
    }

    /// Generation/pane teardown (D4): the connection this coordinator served is
    /// gone, so drop every pending prompt locally — no frames to a dead fd — and
    /// stop the expiry timer, without an announcement (a genuine pane close /
    /// re-mint is not a user-facing "cancelled" event the way a live connection
    /// drop is; `handleConnectionLost` owns that path). Idempotent: a second call
    /// finds an empty map and no timer. Called by the trio teardown that both the
    /// registry (genuine close) and the make-before-break rollback/break-old run.
    func teardownState() {
        expiryTask?.cancel()
        expiryTask = nil
        for entry in pending.drainAll() {
            clearBookkeeping(id: entry.id)
        }
        sessionGrants.removeAll()
        focusedPromptID = nil
        publish()
    }

    // MARK: - C2 seams (mirrors E2's `frameSink`)

    /// Every validated post-handshake frame for this attach, generation-tagged.
    /// Consumes `permission-request` (and `permission-resolved`, the helper's
    /// terminal-state notice — see `handleHelperResolved`); ignores the
    /// read-model types E2 owns and the app→helper `permission-decision` that
    /// never arrives inbound.
    var frameSink: BridgeConnectionSupervisor.FrameSink {
        { [weak self] envelope, generation in
            await self?.handle(envelope, generation: generation)
        }
    }

    /// A connection a replacement just closed (or that dropped). All pendings
    /// belong to the one active connection per attach, so the identity is not
    /// needed: default-deny every pending *locally*, write nothing to the dead
    /// fd. Sequencing guarantees this runs before the replacement's own frames
    /// (the supervisor awaits this sink before the next envelope), so a fresh
    /// generation's requests are never caught in the drain.
    var connectionLostSink: BridgeConnectionSupervisor.ConnectionLostSink {
        { [weak self] _ in
            await self?.handleConnectionLost()
        }
    }

    // MARK: - Inbound frame handling

    @MainActor
    private func handle(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation) {
        switch envelope.message {
        case .permissionRequest(let request):
            admit(id: envelope.id, request: request, generation: generation)
        case .permissionResolved(let resolved):
            handleHelperResolved(resolved)
        case .agentStatus, .paneRename, .handoffNotify, .permissionDecision:
            // agent-status/rename/handoff are E2's read-model frames;
            // permission-decision is app→helper and never arrives inbound.
            break
        }
    }

    private func admit(
        id: String,
        request: PermissionRequest,
        generation: BridgeConnectionActor.Generation
    ) {
        handleGenerationChange(to: generation)

        // Master-switch gate, read live per request (review finding): if the
        // agent-integrations switch went off after this bridge attached,
        // fail-closed deny with no UI so the remote agent unblocks rather than
        // hanging on a prompt the user will never see. Mirrors the read-model
        // adapter's live consent read; a duplicate of an existing pending id
        // can't reach here because nothing is pending once the switch is off.
        guard permissionEnabled() else {
            // Also drain any live queue admitted before the toggle (review H2):
            // leave no actionable banner after integrations are off.
            drainAllWithDenyFrames(reason: .cancelled)
            writeDecision(inReplyTo: id, decision: .deny, scope: .once, target: request.target, generation: generation)
            return
        }

        // Local authoritative deadline: min(helper's expiresAt, our 120 s clamp).
        let nowDate = now()
        let helperDeadline = Date(timeIntervalSince1970: request.expiresAt)
        let clamp = nowDate.addingTimeInterval(BridgeTunables.permissionTimeoutClamp)
        let deadline = min(helperDeadline, clamp)

        // A duplicate wire id: the legitimate pending entry is the authoritative
        // ground truth for the confused-deputy `target` check, so it stays
        // untouched. Drop the duplicate — never re-admit it and (checked before
        // the grant fast-path) never let it collect a second auto-allow.
        guard pending.peek(id: id) == nil else { return }

        // Session-grant fast-path: an exact {tool, target} + generation match
        // answers immediately with no UI — but ONLY while the request is still
        // live. A grant never overrides the deadline: a request already past its
        // deadline on arrival is fail-closed by the normal path below, never
        // auto-allowed (deadline wins, same rule the A4 map enforces once
        // admitted). A near-miss ({tool, other-target} / {other-tool, target})
        // does not match either and falls through to the prompt.
        if deadline > nowDate,
           sessionGrants.contains(SessionGrant(tool: request.tool, target: request.target, generation: generation)) {
            writeDecision(inReplyTo: id, decision: .allow, scope: .session, target: request.target, generation: generation)
            return
        }

        switch pending.admit(id: id, target: request.target, tool: request.tool, expiresAt: deadline) {
        case .admitted:
            context[id] = PromptContext(
                tool: request.tool,
                target: request.target,
                summary: request.summary,
                generation: generation,
                deadline: deadline
            )
            order.append(id)
            publish()
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptArrivedAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .high
            )
            rescheduleExpiry()
        case .overflow:
            // The 5th concurrent request: immediate deny, never enqueued. The
            // helper's map can't flood ours no matter what it claims.
            writeDecision(inReplyTo: id, decision: .deny, scope: .once, target: request.target, generation: generation)
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptCancelledAnnouncement(
                    sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()
                ),
                priority: .medium
            )
        case .duplicate:
            // Unreachable by construction: the `pending.peek(id:) == nil` guard
            // above already returns on any repeated wire id (it has to run before
            // the session-grant fast-path so a duplicate can't collect a second
            // auto-allow), so `admit` never sees a duplicate here. Kept only for
            // switch exhaustiveness; if it ever did fire, the right move is the
            // same — leave the legitimate entry pending and drop the duplicate.
            break
        case .invalidDeadline:
            // Belt-and-suspenders fail-closed deny so a buggy admit path never
            // hangs the agent (review R-7).
            writeDecision(inReplyTo: id, decision: .deny, scope: .once, target: request.target, generation: generation)
        }
    }

    /// Helper's own terminal-state notice for a request (`expired`,
    /// `agent-cancelled`, `connection-lost`, `overflow`). The helper already
    /// resolved it, so the app writes NO decision — it only tears down the UI
    /// and announces. `expired` announces as a timeout; the rest as a
    /// cancellation.
    ///
    /// `permission-resolved` is admitted inbound by the C1 connection actor's
    /// `isAllowedInbound` (commit 39e820ac), so this path is LIVE — a helper's
    /// terminal-state notice reaches here and tears down the matching prompt UI.
    private func handleHelperResolved(_ resolved: PermissionResolved) {
        let event: BridgePendingRequestMap.TerminalEvent
        switch resolved.reason {
        case .expired: event = .expired
        case .agentCancelled, .overflow: event = .cancelled
        case .connectionLost: event = .connectionLost
        }
        resolveLocally(id: resolved.inReplyTo, event: event, writeDenyFrame: false)
    }

    // MARK: - User decisions (banner buttons / focus command)

    /// The banner's Allow. `scope: .once` from the two-button banner; the
    /// coordinator supports `.session` grants for the auto-allow path and tests.
    func allowActive(scope: PermissionDecision.Scope = .once) {
        decideActive(allow: true, scope: scope)
    }

    /// The banner's Deny and the Escape early-deny path both land here.
    func denyActive() {
        decideActive(allow: false, scope: .once)
    }

    /// Applies a user decision to the presented (head) prompt.
    /// Keyboard path prefers `focusedPromptID` when set, and always routes
    /// through `decide` so arm-delay / master-switch gates apply.
    func decideActive(allow: Bool, scope: PermissionDecision.Scope) {
        if let focusedPromptID {
            decide(id: focusedPromptID, allow: allow, scope: scope)
            return
        }
        guard let id = order.first else { return }
        decide(id: id, allow: allow, scope: scope)
    }

    /// The banner's Allow/Deny, bound to the EXACT prompt the view rendered.
    /// A decision is authoritative only for the prompt it was shown against
    /// (adversarial-review finding, convergent across two lanes): a second
    /// click delivered as the banner re-renders in place — the first click
    /// resolved the head and `publish()` promoted the next prompt into the
    /// same on-screen position — would otherwise resolve a request the user
    /// never saw. Same "act only on what you saw" guarantee `publish()`'s
    /// focus reset already gives the keyboard path; this closes the mouse
    /// path. No-ops when `id` is no longer the head.
    func allow(id: String, scope: PermissionDecision.Scope = .once) {
        decide(id: id, allow: true, scope: scope)
    }

    func deny(id: String) {
        decide(id: id, allow: false, scope: .once)
    }

    private func decide(id: String, allow: Bool, scope: PermissionDecision.Scope) {
        guard now() >= decisionsDisarmedUntil else { return }
        guard order.first == id else { return }
        applyUserDecision(id: id, allow: allow, scope: scope)
    }

    /// Moves focus to the active prompt — the one deliberate, user-initiated
    /// focus move (arrival never steals focus). No-ops when nothing is pending.
    /// Sets `promptFocused` (unlocking the keyboard-Allow key mappings) and
    /// announces the move so the focus change is perceivable to VoiceOver, not
    /// just sighted keyboard users.
    func requestFocus() {
        guard let id = activePrompt?.id else { return }
        focusRequestToken &+= 1
        promptFocused = true
        focusedPromptID = id
        announcePermission(
            TerminalAccessibilityAnnouncer.permissionPromptFocusedAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
            priority: .medium
        )
    }

    /// The view calls this when SwiftUI's own focus state reports the banner
    /// lost keyboard focus (Tab/click back to the terminal) while the SAME
    /// prompt is still presented. Distinct from the invalidation in
    /// `publish()`, which only fires when the presented prompt itself changes.
    func clearPromptFocus() {
        promptFocused = false
        focusedPromptID = nil
    }

    /// Drain every pending prompt with a deny frame (connection still live).
    private func drainAllWithDenyFrames(reason: BridgePendingRequestMap.TerminalEvent) {
        let previousHead = order.first
        let ids = order
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let entry = pending.peek(id: id) else { continue }
            let generation = context[id]?.generation
            _ = pending.resolve(id: id, event: reason, now: now())
            clearBookkeeping(id: id)
            if let generation {
                writeDecision(
                    inReplyTo: id,
                    decision: .deny,
                    scope: .once,
                    target: entry.target,
                    generation: generation
                )
            }
        }
        focusedPromptID = nil
        announcePermission(
            TerminalAccessibilityAnnouncer.permissionPromptCancelledAnnouncement(
                sessionTitle: paneTitle(),
                paneDescriptor: paneDescriptor()
            ),
            priority: .medium
        )
        finishResolution(previousHead: previousHead)
    }

    private func applyUserDecision(id: String, allow: Bool, scope: PermissionDecision.Scope) {
        // The integrations switch is live policy, not an attach-time snapshot.
        // If it turned off while a prompt was visible, a stale click or keypress
        // must fail closed rather than authorizing after the user disabled the
        // permission surface.
        if allow, !permissionEnabled() {
            applyUserDecision(id: id, allow: false, scope: .once)
            return
        }
        let nowDate = now()
        // peek before resolve so a decision that races past the deadline leaves
        // the map's atomicity to decide the outcome (deadline wins).
        guard let entry = pending.peek(id: id) else { return }
        let generation = context[id]?.generation
        guard case .resolved(_, let effective) = pending.resolve(id: id, event: .decisionApplied, now: nowDate) else {
            return
        }
        let previousHead = order.first
        clearBookkeeping(id: id)

        switch effective {
        case .expired:
            // The deadline already passed — the user's allow/deny is too late.
            // Deny + announce the timeout it already was (A4's deadline-wins).
            if let generation {
                writeDecision(inReplyTo: id, decision: .deny, scope: .once, target: entry.target, generation: generation)
            }
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptTimedOutAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
        case .decisionApplied:
            let decision: PermissionDecision.Decision = allow ? .allow : .deny
            if let generation {
                writeDecision(inReplyTo: id, decision: decision, scope: scope, target: entry.target, generation: generation)
                if allow, scope == .session {
                    sessionGrants.insert(SessionGrant(tool: entry.tool, target: entry.target, generation: generation))
                }
            }
            // Confirm the decision to VoiceOver (review finding): the success
            // path was the one terminal state left unspoken. A FIFO advance,
            // if one follows in `finishResolution`, reads naturally after this
            // ("Permission granted. Next permission request.").
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptDecidedAnnouncement(
                    allowed: allow, sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()
                ),
                priority: .medium
            )
        case .cancelled, .connectionLost:
            // `resolve` only ever returns these when explicitly asked; a user
            // decision asks for `.decisionApplied`, and the deadline override can
            // only yield `.expired`. Unreachable, but exhaustive by contract.
            break
        }
        finishResolution(previousHead: previousHead)
    }

    // MARK: - Expiry (queued clocks keep running)

    /// Test/timer entry point: sweep every overdue entry (inclusive boundary via
    /// A4), deny + announce each, then advance the FIFO. A queued prompt can
    /// expire here before it ever presented.
    func processExpirations() {
        let previousHead = order.first
        let expired = pending.sweepExpired(now: now())
        for entry in expired {
            let generation = context[entry.id]?.generation
            clearBookkeeping(id: entry.id)
            if let generation {
                writeDecision(inReplyTo: entry.id, decision: .deny, scope: .once, target: entry.target, generation: generation)
            }
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptTimedOutAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
        }
        finishResolution(previousHead: previousHead)
    }

    // MARK: - Connection loss

    /// `internal` (not `private`) so tests can exercise connection loss without
    /// minting a `BridgeConnectionActor.ConnectionID` (its initializer is
    /// `fileprivate`). Production reaches it only through `connectionLostSink`.
    func handleConnectionLost() {
        let hadActive = order.first != nil
        let drained = pending.drainAll()
        for entry in drained {
            // Do NOT write to the dead connection — default-deny is local only.
            clearBookkeeping(id: entry.id)
        }
        focusedPromptID = nil
        if hadActive {
            let nowDate = now()
            let debounced = lastConnectionLostAnnouncedAt.map {
                nowDate.timeIntervalSince($0) < Self.connectionLostAnnouncementDebounce
            } ?? false
            if !debounced {
                lastConnectionLostAnnouncedAt = nowDate
                announcePermission(
                    TerminalAccessibilityAnnouncer.permissionPromptCancelledAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                    priority: .medium
                )
            }
        }
        // No FIFO advancement to announce — everything drained.
        expiryTask?.cancel()
        expiryTask = nil
        publish()
    }

    // MARK: - Shared resolution / publishing

    /// Resolves an id with a helper-driven terminal event (no decision from the
    /// app). `writeDenyFrame` is false for helper-resolved notices (the helper
    /// already resolved it).
    private func resolveLocally(
        id: String,
        event: BridgePendingRequestMap.TerminalEvent,
        writeDenyFrame: Bool
    ) {
        let nowDate = now()
        guard let entry = pending.peek(id: id) else { return }
        let generation = context[id]?.generation
        guard case .resolved(_, let effective) = pending.resolve(id: id, event: event, now: nowDate) else {
            return
        }
        let previousHead = order.first
        clearBookkeeping(id: id)
        if writeDenyFrame, let generation {
            writeDecision(inReplyTo: id, decision: .deny, scope: .once, target: entry.target, generation: generation)
        }
        switch effective {
        case .expired:
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptTimedOutAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
        case .cancelled, .connectionLost, .decisionApplied:
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptCancelledAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
        }
        finishResolution(previousHead: previousHead)
    }

    /// After any removal: republish, announce a FIFO advancement if the head
    /// changed to a still-pending prompt, and reschedule the timer.
    private func finishResolution(previousHead: String?) {
        publish()
        if let newHead = order.first, newHead != previousHead {
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptAdvancedAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
        }
        rescheduleExpiry()
    }

    private func clearBookkeeping(id: String) {
        order.removeAll { $0 == id }
        context[id] = nil
    }

    private func publish() {
        let oldPendingCount = (activePrompt == nil ? 0 : 1) + queuedCount
        let newPrompt: ActivePrompt?
        if let head = order.first, let ctx = context[head] {
            newPrompt = ActivePrompt(id: head, tool: ctx.tool, target: ctx.target, summary: ctx.summary)
        } else {
            newPrompt = nil
        }
        // The presented id changed (resolved, advanced, or drained) — the
        // deliberate keyboard-focus grant was scoped to THAT prompt. A newly
        // presented one (even the very next in the FIFO) has not been
        // deliberately focused yet, matching "arrival never steals focus."
        // Also arm a short decision cooldown so a double-click on Allow cannot
        // authorize the successor that just slid into the same button slot.
        if activePrompt?.id != newPrompt?.id {
            promptFocused = false
            focusedPromptID = nil
            if activePrompt != nil, newPrompt != nil {
                decisionsDisarmedUntil = now().addingTimeInterval(
                    BridgeTunables.permissionDecisionArmDelay
                )
            }
        }
        // Guard the observed writes: `@Observable` invalidates on assignment
        // regardless of equality, so a queued (non-head) arrival would otherwise
        // needlessly re-render the banner even though what it shows is unchanged.
        if activePrompt != newPrompt { activePrompt = newPrompt }
        let newCount = max(0, order.count - 1)
        if queuedCount != newCount { queuedCount = newCount }
        let newPendingCount = order.count
        if oldPendingCount != newPendingCount {
            pendingCountChanged(oldPendingCount, newPendingCount)
        }
    }

    /// A new connection generation is a re-mint: the previous connection is dead.
    /// Retire its session grants AND its still-pending prompts locally — no frames
    /// to the dead fd, exactly like a connection loss — so a stale prompt can't
    /// keep consuming the cap/FIFO or be actioned onto a replaced fd.
    ///
    /// Defense in depth: the supervisor already fires `connectionLostSink` for the
    /// replaced connection *before* this generation's first frame reaches the
    /// frame sink, so in the normal flow the old pendings are already drained and
    /// this finds nothing stale. It keeps the coordinator correct even if that
    /// ordering ever regresses — and it means a later unscoped `handleConnectionLost`
    /// can't sweep a fresh generation's prompts, because the transition already
    /// retired only the superseded generation's state.
    private func handleGenerationChange(to generation: BridgeConnectionActor.Generation) {
        guard latestGeneration != generation else { return }
        sessionGrants = sessionGrants.filter { $0.generation == generation }

        let stale = order.filter { context[$0]?.generation != generation }
        if !stale.isEmpty {
            let previousHead = order.first
            for id in stale {
                _ = pending.resolve(id: id, event: .connectionLost, now: now())
                clearBookkeeping(id: id)
            }
            announcePermission(
                TerminalAccessibilityAnnouncer.permissionPromptCancelledAnnouncement(sessionTitle: paneTitle(), paneDescriptor: paneDescriptor()),
                priority: .medium
            )
            finishResolution(previousHead: previousHead)
        }
        latestGeneration = generation
    }

    private func rescheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let nearest = context.values.map(\.deadline).min() else { return }
        let delay = nearest.timeIntervalSince(now())
        // `Task {}` inherits this MainActor isolation, so `sleep` suspends on the
        // main actor and `processExpirations()` runs same-actor (no hop) — which
        // is exactly the serialization the one-authoritative-instance rule wants.
        expiryTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            // Re-check master switch on every timer fire so a mid-session
            // toggle-off drains live prompts without waiting for a new admit.
            if let self, !self.permissionEnabled() {
                self.drainAllWithDenyFrames(reason: .cancelled)
                return
            }
            self?.processExpirations()
        }
    }

    private func writeDecision(
        inReplyTo: String,
        decision: PermissionDecision.Decision,
        scope: PermissionDecision.Scope,
        target: String,
        generation: BridgeConnectionActor.Generation
    ) {
        let envelope = BridgeEnvelope(
            token: expectedToken,
            session: expectedSession,
            id: "dec-\(UUID().uuidString)",
            ts: now().timeIntervalSince1970,
            message: .permissionDecision(
                PermissionDecision(inReplyTo: inReplyTo, decision: decision, scope: scope, target: target)
            )
        )
        sendDecision(envelope, generation)
    }

    private func announcePermission(_ message: String, priority: NSAccessibilityPriorityLevel) {
        announce(message, priority)
    }

    // MARK: - Supporting value types

    private struct PromptContext {
        let tool: String
        let target: String
        let summary: String?
        let generation: BridgeConnectionActor.Generation
        let deadline: Date
    }

    /// Exact-pair-plus-generation grant key. `Hashable` on all three fields, so a
    /// near-miss on tool or target — or a stale generation — simply doesn't match.
    private struct SessionGrant: Hashable {
        let tool: String
        let target: String
        let generation: BridgeConnectionActor.Generation
    }
}
