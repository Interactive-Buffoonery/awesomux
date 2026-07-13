import AppKit
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

/// Verifies the app-side twin (`BridgePermissionCoordinator`) enforces the
/// permission-lifecycle policy the spec makes app-authoritative — cap, local
/// deadline clamp, FIFO with queued clocks, session-grant boundary,
/// generation-tagged writes, never-send-after-resolved, and the accessibility
/// announcements — with spy write/announce seams, an injected clock, and NO
/// live sockets. The A4 invariant core (`BridgePendingRequestMap`) is wrapped,
/// not re-tested here.
@MainActor
@Suite("Bridge permission coordinator")
struct BridgePermissionCoordinatorTests {

    // MARK: - Harness

    /// Fixed epoch so deadline math is exact. All offsets are relative to this.
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static let resourcesBundle =
        Bundle(
            url: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Resources", directoryHint: .isDirectory)
        ) ?? .main

    private final class DecisionSpy: @unchecked Sendable {
        var writes: [(envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation)] = []
        var decisions: [PermissionDecision] {
            writes.compactMap {
                if case .permissionDecision(let decision) = $0.envelope.message { return decision }
                return nil
            }
        }
    }

    private final class AnnounceSpy: @unchecked Sendable {
        var messages: [String] = []
    }

    private struct Harness {
        let coordinator: BridgePermissionCoordinator
        let clock: TestClock
        let decisions: DecisionSpy
        let announcements: AnnounceSpy
    }

    private static let token = "tok-abc"
    private static let session = "sess-uuid"

    private func makeHarness(
        permissionEnabled: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> Harness {
        let clock = TestClock(Self.t0)
        let decisions = DecisionSpy()
        let announcements = AnnounceSpy()
        let coordinator = BridgePermissionCoordinator(
            expectedToken: Self.token,
            expectedSession: Self.session,
            paneTitle: { "web" },
            paneDescriptor: { nil },
            now: { clock.now },
            sendDecision: { envelope, generation in decisions.writes.append((envelope, generation)) },
            announce: { message, _ in announcements.messages.append(message) },
            permissionEnabled: permissionEnabled,
            // Never auto-fire the timer; tests drive expiry via processExpirations().
            sleep: { _ in try? await Task.sleep(for: .seconds(86_400)) }
        )
        return Harness(coordinator: coordinator, clock: clock, decisions: decisions, announcements: announcements)
    }

    private func request(
        id: String,
        tool: String = "Bash",
        target: String = "rm -rf ./build",
        summary: String? = nil,
        expiresAtOffset: TimeInterval
    ) -> BridgeEnvelope {
        BridgeEnvelope(
            token: Self.token,
            session: Self.session,
            id: id,
            ts: Self.t0.timeIntervalSince1970,
            message: .permissionRequest(
                PermissionRequest(
                    tool: tool,
                    target: target,
                    summary: summary,
                    expiresAt: Self.t0.addingTimeInterval(expiresAtOffset).timeIntervalSince1970
                )
            )
        )
    }

    private func gen(_ raw: UInt64) -> BridgeConnectionActor.Generation {
        BridgeConnectionActor.makeGenerationForTesting(raw)
    }

    private func deliver(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation, to h: Harness) async {
        await h.coordinator.frameSink(envelope, generation)
    }

    // MARK: - App-side cap

    @Test("app-twin cap denies the 5th request with an immediate deny frame and never enqueues it")
    func appTwinCapDeniesFifth() async {
        let h = makeHarness()
        let g = gen(1)
        for index in 1...4 {
            await deliver(request(id: "r\(index)", target: "t\(index)", expiresAtOffset: 1000), generation: g, to: h)
        }
        #expect(h.decisions.writes.isEmpty)  // four admitted, none answered
        #expect(h.coordinator.activePrompt?.id == "r1")
        #expect(h.coordinator.queuedCount == 3)

        await deliver(request(id: "r5", target: "t5", expiresAtOffset: 1000), generation: g, to: h)

        // The 5th is denied immediately and never enqueued.
        #expect(h.decisions.writes.count == 1)
        #expect(h.decisions.decisions.first?.decision == .deny)
        #expect(h.decisions.decisions.first?.inReplyTo == "r5")
        #expect(h.coordinator.activePrompt?.id == "r1")
        #expect(h.coordinator.queuedCount == 3)  // still four pending, UI untouched
        #expect(h.announcements.messages.contains { $0.contains("cancelled") })
    }

    // MARK: - Local deadline clamp

    @Test("local clamp fires at the inclusive boundary when the helper never resolves")
    func localClampFiresInclusive() async {
        let h = makeHarness()
        // Helper deadline far in the future — the app's 120 s clamp must win.
        await deliver(request(id: "r1", expiresAtOffset: 1000), generation: gen(1), to: h)
        #expect(h.coordinator.activePrompt?.id == "r1")

        // One second before the clamp: still pending, nothing written.
        h.clock.set(Self.t0.addingTimeInterval(BridgeTunables.permissionTimeoutClamp - 1))
        h.coordinator.processExpirations()
        #expect(h.coordinator.activePrompt?.id == "r1")
        #expect(h.decisions.writes.isEmpty)

        // Exactly at the clamp (inclusive: now >= deadline): denied + torn down.
        h.clock.set(Self.t0.addingTimeInterval(BridgeTunables.permissionTimeoutClamp))
        h.coordinator.processExpirations()
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.decisions.decisions.count == 1)
        #expect(h.decisions.decisions.first?.decision == .deny)
        #expect(h.announcements.messages.contains { $0.contains("timed out") })
    }

    @Test("clamp picks the helper's earlier expiresAt when it is sooner than 120 s")
    func clampPicksEarlierHelperDeadline() async {
        let h = makeHarness()
        await deliver(request(id: "r1", expiresAtOffset: 30), generation: gen(1), to: h)
        // Just before the helper's 30 s deadline (< the 120 s clamp): pending.
        h.clock.set(Self.t0.addingTimeInterval(29))
        h.coordinator.processExpirations()
        #expect(h.coordinator.activePrompt?.id == "r1")
        // At 30 s: fires (the min picked the helper deadline, not the clamp).
        h.clock.set(Self.t0.addingTimeInterval(30))
        h.coordinator.processExpirations()
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.decisions.decisions.first?.decision == .deny)
    }

    // MARK: - FIFO

    @Test("a queued request can expire before it ever presents; the FIFO advances and announces")
    func queuedRequestExpiresBeforePresentation() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)  // active, far deadline
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 30), generation: g, to: h)  // queued, short deadline
        #expect(h.coordinator.activePrompt?.id == "r1")
        #expect(h.coordinator.queuedCount == 1)

        // r2 (still queued, never presented) expires.
        h.clock.set(Self.t0.addingTimeInterval(30))
        h.coordinator.processExpirations()

        #expect(h.coordinator.activePrompt?.id == "r1")  // r1 keeps presenting
        #expect(h.coordinator.queuedCount == 0)
        #expect(h.decisions.decisions.contains { $0.inReplyTo == "r2" && $0.decision == .deny })
        #expect(h.announcements.messages.contains { $0.contains("timed out") })
    }

    @Test("denying the active prompt advances the FIFO to the next and announces it")
    func denyAdvancesFifoAndAnnounces() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)

        h.coordinator.denyActive()

        #expect(h.decisions.decisions.contains { $0.inReplyTo == "r1" && $0.decision == .deny })
        #expect(h.coordinator.activePrompt?.id == "r2")
        #expect(h.coordinator.queuedCount == 0)
        #expect(h.announcements.messages.contains { $0.contains("Next permission request") })
    }

    @Test("the master switch off fail-closed denies a request with no UI")
    func masterSwitchOffDeniesWithoutUI() async {
        let h = makeHarness(permissionEnabled: { false })
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        // Fail-closed deny frame so the agent unblocks; nothing enqueued in UI.
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.decisions.decisions.contains { $0.inReplyTo == "r1" && $0.decision == .deny })
        #expect(h.coordinator.queuedCount == 0)
    }

    @Test("turning the master switch off makes an already-visible Allow fail closed")
    func liveSwitchOffDeniesExistingPrompt() async {
        let gate = PermissionGate()
        let h = makeHarness(permissionEnabled: { gate.enabled })
        await deliver(request(id: "r1", expiresAtOffset: 1000), generation: gen(1), to: h)
        gate.enabled = false

        h.coordinator.allowActive()

        #expect(h.decisions.decisions.first?.decision == .deny)
        #expect(h.coordinator.activePrompt == nil)
    }

    @Test("a user decision on the last prompt is announced to VoiceOver")
    func decisionAnnouncedOnLastPrompt() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.allow(id: "r1")
        #expect(h.coordinator.activePrompt == nil)
        // The success path must not be silent (review finding).
        #expect(h.announcements.messages.contains { $0.contains("Permission granted") })
    }

    @Test("an id-bound decision is authoritative only for the prompt it was shown against")
    func idBoundDecisionNoOpsOnStalePrompt() async {
        // Adversarial-review finding (convergent): a second click delivered as
        // the banner re-renders in place must NOT resolve the promoted next
        // prompt the user never saw.
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)

        // First click resolves the shown prompt (r1); r2 promotes into place.
        h.coordinator.allow(id: "r1")
        #expect(h.coordinator.activePrompt?.id == "r2")

        // A second click still carrying r1's id (the rendered prompt) is now
        // stale — it must NOT resolve r2.
        h.coordinator.allow(id: "r1")
        #expect(h.coordinator.activePrompt?.id == "r2")
        #expect(!h.decisions.decisions.contains { $0.inReplyTo == "r2" })

        // Immediate correctly-bound click for r2 is also blocked by the
        // post-advance arm delay (double-click protection).
        h.coordinator.allow(id: "r2")
        #expect(!h.decisions.decisions.contains { $0.inReplyTo == "r2" })

        // After the arm delay, the correctly-bound click for r2 works.
        h.clock.advance(by: BridgeTunables.permissionDecisionArmDelay)
        h.coordinator.allow(id: "r2")
        #expect(h.decisions.decisions.contains { $0.inReplyTo == "r2" && $0.decision == .allow })
        #expect(h.coordinator.activePrompt == nil)
    }

    @Test("FIFO advance disarms decisions briefly so a double-click cannot authorize the next prompt")
    func fifoAdvanceDisarmsDoubleClick() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.allow(id: "r1")
        #expect(h.coordinator.activePrompt?.id == "r2")

        // Second half of a double-click lands on r2's Allow immediately — no-op.
        h.coordinator.allow(id: "r2")
        #expect(!h.decisions.decisions.contains { $0.inReplyTo == "r2" })
        #expect(h.coordinator.activePrompt?.id == "r2")
    }

    @Test("keyboard allow binds to the focused prompt id, not a successor head")
    func keyboardAllowBindsToFocusedPromptID() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.requestFocus()
        #expect(h.coordinator.promptFocused)

        h.coordinator.allowActive()
        #expect(h.decisions.decisions.contains { $0.inReplyTo == "r1" && $0.decision == .allow })
        // Focus does not carry to r2; arm delay also applies.
        #expect(h.coordinator.promptFocused == false)
        #expect(h.coordinator.activePrompt?.id == "r2")
        h.coordinator.allowActive()
        #expect(!h.decisions.decisions.contains { $0.inReplyTo == "r2" })
    }

    @Test("master switch off mid-banner drains live prompts with deny frames")
    func masterSwitchOffDrainsLiveQueue() async {
        let gate = PermissionGate()
        let h = makeHarness(permissionEnabled: { gate.enabled })
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt?.id == "r1")

        gate.enabled = false
        // Next admit drains the live queue and denies the new request.
        await deliver(request(id: "r3", target: "t3", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.decisions.decisions.filter { $0.decision == .deny }.count >= 3)
    }

    // MARK: - Session grants

    @Test("a session grant answers an exact {tool,target} match immediately; near-misses do not")
    func sessionGrantExactMatchOnlyAnswersWithoutUI() async {
        let h = makeHarness()
        let g = gen(1)
        // Establish a session grant via a user allow(session).
        await deliver(request(id: "r1", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.allowActive(scope: .session)
        #expect(h.coordinator.activePrompt == nil)
        let baselineWrites = h.decisions.writes.count  // the allow(session) for r1

        // Exact pair + same generation → answered immediately, no UI.
        await deliver(request(id: "r2", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.decisions.writes.count == baselineWrites + 1)
        #expect(h.decisions.decisions.last?.decision == .allow)
        #expect(h.decisions.decisions.last?.inReplyTo == "r2")

        // Near-miss on target → NOT matched, enqueued for the user.
        await deliver(request(id: "r3", tool: "Bash", target: "rm -rf ./other", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt?.id == "r3")

        h.coordinator.denyActive()  // clear r3

        // Near-miss on tool → NOT matched, enqueued.
        await deliver(request(id: "r4", tool: "Other", target: "rm -rf ./build", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt?.id == "r4")
    }

    @Test("a request already past its deadline on arrival is never auto-allowed by a grant")
    func expiredOnArrivalNotAutoAllowedByGrant() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.allowActive(scope: .session)
        let baseline = h.decisions.writes.count

        // A matching request whose helper deadline is already in the past.
        h.clock.set(Self.t0.addingTimeInterval(500))
        await deliver(request(id: "r2", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 100), generation: g, to: h)

        // The grant did NOT shortcut it to allow (deadline wins) — it entered the
        // normal path instead, where it will be denied on the next sweep.
        #expect(h.decisions.writes.count == baseline)
        #expect(h.coordinator.activePrompt?.id == "r2")
    }

    // MARK: - Duplicate ids

    @Test("a duplicate request id is dropped, not enqueued or answered twice")
    func duplicateRequestIdDropped() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.activePrompt?.id == "r1")
        #expect(h.coordinator.queuedCount == 0)

        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.queuedCount == 0)  // not re-enqueued
        #expect(h.decisions.writes.isEmpty)  // not answered
    }

    // MARK: - Generation transition drains stale pendings

    @Test("a generation change retires the previous generation's pendings locally, no frames to the dead fd")
    func generationChangeDrainsStalePendings() async {
        let h = makeHarness()
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: gen(1), to: h)
        #expect(h.coordinator.activePrompt?.id == "r1")

        // A new-generation request (re-mint) arrives before any connection-loss
        // callback. r1 (old generation) must be retired without a frame.
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: gen(2), to: h)

        #expect(h.coordinator.activePrompt?.id == "r2")
        #expect(h.coordinator.queuedCount == 0)
        #expect(h.decisions.writes.isEmpty)  // nothing written for retired r1
        #expect(h.announcements.messages.contains { $0.contains("cancelled") })
    }

    @Test("a generation bump kills session grants — a re-mint requires a fresh decision")
    func generationBumpKillsGrants() async {
        let h = makeHarness()
        await deliver(request(id: "r1", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 1000), generation: gen(1), to: h)
        h.coordinator.allowActive(scope: .session)
        #expect(h.coordinator.activePrompt == nil)

        // Same {tool,target} but a NEW generation — the grant must not carry over.
        await deliver(request(id: "r2", tool: "Bash", target: "rm -rf ./build", expiresAtOffset: 1000), generation: gen(2), to: h)
        #expect(h.coordinator.activePrompt?.id == "r2")  // enqueued, not auto-allowed
    }

    // MARK: - Return-never-Allow contract

    @Test("Escape denies and Return/Enter map to nothing — Allow has no key mapping")
    func returnNeverMapsToAllow() {
        #expect(BridgePermissionPromptKey.action(forKeyCode: 53) == .deny)  // Escape
        #expect(BridgePermissionPromptKey.action(forKeyCode: 36) == nil)  // Return
        #expect(BridgePermissionPromptKey.action(forKeyCode: 76) == nil)  // keypad Enter
        #expect(BridgePermissionPromptKey.action(forKeyCode: 49) == nil)  // Space
    }

    // MARK: - Focused keyboard-Allow (INT-698 addendum, USER RULING)

    @Test("unfocused: Return, ⌘Return, and A all map to nothing; Escape still denies")
    func unfocusedKeyMapNeverAllows() {
        #expect(BridgePermissionPromptKey.action(forKeyCode: 36, modifierFlags: [], focused: false) == nil)
        #expect(BridgePermissionPromptKey.action(forKeyCode: 36, modifierFlags: .command, focused: false) == nil)
        #expect(BridgePermissionPromptKey.action(forKeyCode: 0, modifierFlags: [], focused: false) == nil)
        #expect(BridgePermissionPromptKey.action(forKeyCode: 53, modifierFlags: [], focused: false) == .deny)
    }

    @Test("focused: ⌘Return and A allow; bare Return and keypad Enter still map to nothing; Escape still denies")
    func focusedKeyMapAllowsCommandReturnAndA() {
        #expect(BridgePermissionPromptKey.action(forKeyCode: 36, modifierFlags: .command, focused: true) == .allow)
        #expect(BridgePermissionPromptKey.action(forKeyCode: 0, modifierFlags: [], focused: true) == .allow)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift, [.control, .option]] {
            #expect(BridgePermissionPromptKey.action(forKeyCode: 0, modifierFlags: modifiers, focused: true) == nil)
        }
        #expect(BridgePermissionPromptKey.action(forKeyCode: 36, modifierFlags: [], focused: true) == nil)  // bare Return
        #expect(BridgePermissionPromptKey.action(forKeyCode: 76, modifierFlags: [], focused: true) == nil)  // keypad Enter
        #expect(BridgePermissionPromptKey.action(forKeyCode: 53, modifierFlags: [], focused: true) == .deny)  // Escape
    }

    @Test("requestFocus sets the focused flag and announces; resolving/advancing the prompt clears it")
    func requestFocusSetsFlagAndClearsOnResolution() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)

        h.coordinator.requestFocus()
        #expect(h.coordinator.promptFocused)
        #expect(h.announcements.messages.contains { $0.contains("focused") })

        // Resolving the focused (head) prompt advances the FIFO — the flag
        // must NOT carry over to the newly-presented prompt (arrival never
        // steals focus, so the new head starts out unfocused).
        h.coordinator.denyActive()
        #expect(h.coordinator.activePrompt?.id == "r2")
        #expect(!h.coordinator.promptFocused)
    }

    @Test("clearPromptFocus clears the flag without resolving the prompt (focus returned to the terminal)")
    func clearPromptFocusClearsWithoutResolving() async {
        let h = makeHarness()
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: gen(1), to: h)
        h.coordinator.requestFocus()
        #expect(h.coordinator.promptFocused)

        h.coordinator.clearPromptFocus()

        #expect(!h.coordinator.promptFocused)
        #expect(h.coordinator.activePrompt?.id == "r1")  // prompt itself is untouched
    }

    // MARK: - Never-send-after-resolved

    @Test("a decision that lands after the deadline denies (deadline wins) and never double-writes")
    func lateDecisionAfterDeadlineDeniesAndNeverDoubleWrites() async {
        let h = makeHarness()
        await deliver(request(id: "r1", expiresAtOffset: 30), generation: gen(1), to: h)

        // Move past the deadline WITHOUT firing the timer, then the user clicks
        // Allow: A4's deadline-wins relabel forces a deny + timeout announce.
        h.clock.set(Self.t0.addingTimeInterval(40))
        h.coordinator.allowActive()

        #expect(h.decisions.decisions.count == 1)
        #expect(h.decisions.decisions.first?.decision == .deny)  // NOT allow
        #expect(h.announcements.messages.contains { $0.contains("timed out") })
        #expect(h.coordinator.activePrompt == nil)

        // A second decision (or a late timer sweep) writes nothing more.
        h.coordinator.allowActive()
        h.coordinator.processExpirations()
        #expect(h.decisions.decisions.count == 1)
    }

    // MARK: - Connection loss

    @Test("connection loss default-denies pendings locally with no frames to the dead connection")
    func connectionLossDefaultDeniesWithoutWriting() async {
        let h = makeHarness()
        let g = gen(1)
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)
        #expect(h.coordinator.queuedCount == 1)

        h.coordinator.handleConnectionLost()

        #expect(h.decisions.writes.isEmpty)  // nothing sent to the dead fd
        #expect(h.coordinator.activePrompt == nil)
        #expect(h.coordinator.queuedCount == 0)
        #expect(h.announcements.messages.contains { $0.contains("cancelled") })
    }

    @Test("a flapping bridge coalesces connection-loss cancellations within the debounce window")
    func connectionLossAnnouncementsDebounce() async {
        let h = makeHarness()
        let g = gen(1)

        // Cycle 1: a prompt arrives, the connection dies → one announcement.
        await deliver(request(id: "r1", target: "t1", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.handleConnectionLost()

        // Cycle 2: a new prompt arrives and the connection dies again 1s later,
        // inside the debounce window → drained/denied but NOT re-announced.
        h.clock.set(Self.t0.addingTimeInterval(1))
        await deliver(request(id: "r2", target: "t2", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.handleConnectionLost()

        #expect(h.announcements.messages.filter { $0.contains("cancelled") }.count == 1)
        #expect(h.coordinator.activePrompt == nil)  // still drained each cycle

        // Cycle 3: past the debounce window → announces again.
        h.clock.set(
            Self.t0.addingTimeInterval(
                BridgePermissionCoordinator.connectionLostAnnouncementDebounceForTesting + 1
            ))
        await deliver(request(id: "r3", target: "t3", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.handleConnectionLost()

        #expect(h.announcements.messages.filter { $0.contains("cancelled") }.count == 2)
    }

    // MARK: - Generation tagging

    @Test("a decision is written with the request's own connection generation")
    func decisionCarriesRequestGeneration() async {
        let h = makeHarness()
        let g = gen(7)
        await deliver(request(id: "r1", expiresAtOffset: 1000), generation: g, to: h)
        h.coordinator.denyActive()
        #expect(h.decisions.writes.first?.generation == g)
    }

    // MARK: - UI-level accessibility

    @Test("the banner accessibility label carries the full target even when display would elide it")
    func accessibilityLabelCarriesFullTarget() {
        let longTarget = String(repeating: "rm -rf /very/long/path/segment ", count: 8)
        let label = BridgePermissionPromptView.accessibilityLabel(
            tool: "Bash",
            target: longTarget,
            summary: "Delete build directory",
            queuedCount: 2
        )
        #expect(label.contains(longTarget))  // full, untruncated
        #expect(label.contains("Bash"))
        #expect(label.contains("Delete build directory"))
    }

    @Test("mixed-script request text raises the homograph-spoof warning in tool, target, or summary")
    func mixedScriptTextFlagsSpoofWarning() {
        // A plain ASCII request is never flagged.
        #expect(
            !BridgePermissionPromptView.hasSuspiciousText(
                tool: "Bash", target: "rm -rf ./build", summary: "Delete build directory"
            ))
        // A legitimate single-script non-Latin path is NOT flagged (no rejection
        // of real non-Latin content).
        #expect(
            !BridgePermissionPromptView.hasSuspiciousText(
                tool: "Bash", target: "кот", summary: nil
            ))
        // A Cyrillic lookalike smuggled into an otherwise-Latin target IS flagged
        // (the "а" in "pаsswd" is U+0430).
        #expect(
            BridgePermissionPromptView.hasSuspiciousText(
                tool: "Bash", target: "cat /etc/pаsswd", summary: nil
            ))
        // Any field alone can trip it — here the summary.
        #expect(
            BridgePermissionPromptView.hasSuspiciousText(
                tool: "Bash", target: "ls", summary: "Reаd files"
            ))
    }

    @Test("the accessibility label appends the spoof warning when the request mixes scripts")
    func accessibilityLabelAppendsSpoofWarning() {
        let clean = BridgePermissionPromptView.accessibilityLabel(
            tool: "Bash", target: "rm -rf ./build", summary: nil, queuedCount: 0
        )
        #expect(!clean.contains("disguised"))

        let spoofed = BridgePermissionPromptView.accessibilityLabel(
            tool: "Bash", target: "cat /etc/pаsswd", summary: nil, queuedCount: 0
        )
        #expect(spoofed.contains("disguised"))
    }

    @Test("the queue badge count uses the stringsdict plural, not a manual singular/plural switch")
    func queueBadgeUsesPluralEntry() {
        let one = LocalizedPluralStrings.bridgePermissionQueuedCount(count: 1, bundle: Self.resourcesBundle)
        let many = LocalizedPluralStrings.bridgePermissionQueuedCount(count: 2, bundle: Self.resourcesBundle)
        #expect(one.contains("1"))
        #expect(one.contains("request waiting"))
        #expect(!one.contains("requests"))
        #expect(many.contains("2"))
        #expect(many.contains("requests waiting"))
    }
}

@MainActor
private final class PermissionGate {
    var enabled = true
}
