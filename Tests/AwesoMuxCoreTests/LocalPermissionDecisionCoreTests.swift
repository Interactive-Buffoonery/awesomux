import Foundation
import Testing
@testable import AwesoMuxCore

@Suite @MainActor
struct LocalPermissionDecisionCoreTests {
    let now = Date(timeIntervalSince1970: 1000)

    func fixture() -> (LocalPermissionDecisionCore, LocalPermissionRequest) {
        let core = LocalPermissionDecisionCore()
        let target = LocalPermissionTarget(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(), version: UUID())
        core.install(target)
        core.observeSession("claude-session", target: target, at: now)
        let request = LocalPermissionRequest(
            target: target, providerSessionID: "claude-session", invocationID: UUID(), toolUseID: "tool-1", helperPID: 123,
            helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(120), tool: "Bash", summary: "echo hello")
        return (core, request)
    }

    @Test func firstCommitWinsAndFallbackDoesNotReopen() {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        #expect(core.admit(request, now: now, helperAlive: true))
        #expect(core.commit(request.identity, choice: .allow, now: now, helperAlive: true) == .recorded)
        #expect(core.commit(request.identity, choice: .deny, now: now, helperAlive: true) == .recorded)
        #expect(core.outcome(request.identity)?.choice == .allow)
        #expect(core.claimDelivery(request.identity, now: now, helperAlive: true) == .allow)
        #expect(core.claimDelivery(request.identity, now: now, helperAlive: true) == nil)
        core.deliveryLost(request.identity)
        #expect(core.admit(request, now: now, helperAlive: true))
        #expect(core.outcome(request.identity)?.state == .unknown)
        #expect(core.claimDelivery(request.identity, now: now, helperAlive: true) == nil)
    }

    @Test func acknowledgementRequiresClaimAndExactIdentity() {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        core.acknowledge(request.identity)
        #expect(core.outcome(request.identity)?.state == .pending)
        _ = core.commit(request.identity, choice: .deny, now: now, helperAlive: true)
        _ = core.claimDelivery(request.identity, now: now, helperAlive: true)
        var wrong = request.identity
        wrong.revision += 1
        core.acknowledge(wrong)
        #expect(core.outcome(request.identity)?.state == .delivering)
        core.acknowledge(request.identity)
        #expect(core.outcome(request.identity)?.state == .delivered)
    }

    @Test func expiryAndDeadHelperProduceNoDecision() {
        for dead in [false, true] {
            let (core, request) = fixture()
            #expect(core.admit(request, now: now, helperAlive: true))
            let instant = dead ? now : request.expiresAt
            _ = core.commit(request.identity, choice: .allow, now: instant, helperAlive: !dead)
            #expect(core.claimDelivery(request.identity, now: instant, helperAlive: !dead) == nil)
            #expect(core.outcome(request.identity)?.state == (dead ? .cancelled : .expired))
        }
    }

    @Test func targetAndSessionChangesInvalidateRecordedAnswers() {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        _ = core.commit(request.identity, choice: .allow, now: now, helperAlive: true)
        core.observeSession("replacement", target: request.target, at: now)
        #expect(core.outcome(request.identity)?.state == .cancelled)
        #expect(core.claimDelivery(request.identity, now: now, helperAlive: true) == nil)
        core.retire(request.target)
        #expect(!core.admit(request, now: now, helperAlive: true))
    }

    @Test func progressAfterClaimBecomesUnknown() {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        _ = core.commit(request.identity, choice: .allow, now: now, helperAlive: true)
        _ = core.claimDelivery(request.identity, now: now, helperAlive: true)
        core.cancel(request.identity)
        core.acknowledge(request.identity)
        #expect(core.outcome(request.identity)?.state == .unknown)
    }

    @Test(arguments: [0, 1, 2, 3], [LocalPermissionChoice.allow, .deny])
    func nativeProgressRacingMacDecisionCannotProduceAnotherAnswer(progressStage: Int, choice: LocalPermissionChoice) {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        let instant = now.addingTimeInterval(1)
        func nativeProgress() {
            core.observeProgress(
                session: request.providerSessionID, target: request.target,
                at: instant, toolUseID: request.toolUseID
            )
        }
        if progressStage == 0 { nativeProgress() }
        #expect(
            core.commit(request.identity, choice: choice, now: instant, helperAlive: true)
                == (progressStage == 0 ? .cancelled : .recorded))
        if progressStage == 1 { nativeProgress() }
        #expect(core.claimDelivery(request.identity, now: instant, helperAlive: true) == (progressStage < 2 ? nil : choice))
        if progressStage == 2 { nativeProgress() }
        core.acknowledge(request.identity)
        if progressStage == 3 { nativeProgress() }
        let expected: LocalPermissionState = progressStage < 2 ? .cancelled : (progressStage == 2 ? .unknown : .delivered)
        #expect(core.outcome(request.identity)?.state == expected)
        #expect(core.admit(request, now: instant, helperAlive: true))
        let competing: LocalPermissionChoice = choice == .allow ? .deny : .allow
        #expect(core.commit(request.identity, choice: competing, now: instant, helperAlive: true) == expected)
        #expect(core.claimDelivery(request.identity, now: instant, helperAlive: true) == nil)
        #expect(core.outcome(request.identity)?.choice == (progressStage == 0 ? nil : choice))
    }

    @Test func changedIngressAndRetentionCannotRemint() {
        let (core, request) = fixture()
        #expect(core.admit(request, now: now, helperAlive: true))
        var changed = request
        changed.summary = "different"
        #expect(!core.admit(changed, now: now, helperAlive: true))
        core.sweep(now: request.expiresAt.addingTimeInterval(601))
        #expect(core.outcome(request.identity) == nil)
        #expect(!core.admit(request, now: request.expiresAt.addingTimeInterval(601), helperAlive: true))
    }
    @Test func cancellationIsExactAcrossConcurrentAndReplacedSessions() {
        let (core, first) = fixture()
        let older = LocalPermissionRequest(
            target: first.target, providerSessionID: first.providerSessionID, invocationID: UUID(), toolUseID: nil,
            helperPID: 123, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(120), tool: "Bash", summary: "older"
        )
        let sibling = LocalPermissionRequest(
            target: first.target, providerSessionID: first.providerSessionID, invocationID: UUID(), toolUseID: nil,
            helperPID: 124, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(120), tool: "Bash", summary: "sibling"
        )
        #expect(core.admit(older, now: now, helperAlive: true))
        #expect(core.admit(sibling, now: now, helperAlive: true))
        core.cancel(older.identity)
        #expect(core.outcome(sibling.identity)?.state == .pending)
        core.observeSession("new-session", target: first.target, at: now)
        let replacement = LocalPermissionRequest(
            target: first.target, providerSessionID: "new-session", invocationID: UUID(), toolUseID: nil,
            helperPID: 125, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(120), tool: "Bash", summary: "replacement"
        )
        #expect(core.admit(replacement, now: now, helperAlive: true))
        // A delayed old event or file withdrawal names only its old identity.
        core.cancel(older.identity)
        #expect(core.outcome(replacement.identity)?.state == .pending)
    }

    @Test func delayedSessionStartCannotReplaceVerifiedIngress() {
        let core = LocalPermissionDecisionCore()
        let target = LocalPermissionTarget(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(), version: UUID())
        core.install(target)
        let request = LocalPermissionRequest(
            target: target, providerSessionID: "current", invocationID: UUID(), toolUseID: nil,
            helperPID: 123, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(120), tool: "Bash", summary: "current"
        )
        #expect(core.admit(request, now: now, helperAlive: true))
        core.observeSession("old", target: target, at: now.addingTimeInterval(-1))
        #expect(core.commit(request.identity, choice: .allow, now: now, helperAlive: true) == .recorded)
    }

    @Test func delayedAdmissionDoesNotHideNewerSessionStart() {
        let (core, old) = fixture()
        let sessionStart = now.addingTimeInterval(1)
        let admission = now.addingTimeInterval(2)
        #expect(old.issuedAt < sessionStart && sessionStart < admission)
        #expect(core.admit(old, now: admission, helperAlive: true))
        core.observeSession("replacement", target: old.target, at: sessionStart)
        #expect(core.outcome(old.identity)?.state == .cancelled)
        #expect(core.commit(old.identity, choice: .allow, now: admission, helperAlive: true) == .cancelled)
        #expect(core.claimDelivery(old.identity, now: admission, helperAlive: true) == nil)
        let replacement = LocalPermissionRequest(
            target: old.target, providerSessionID: "replacement", invocationID: UUID(), toolUseID: nil,
            helperPID: 124, helperStartMicroseconds: 1, expiresAt: sessionStart.addingTimeInterval(120),
            tool: "Bash", summary: "replacement"
        )
        #expect(core.admit(replacement, now: admission, helperAlive: true))
        #expect(core.commit(replacement.identity, choice: .deny, now: admission, helperAlive: true) == .recorded)
    }

    @Test func olderIngressPreservesNewerExplicitSessionEvidence() {
        let (core, request) = fixture()
        let explicitStart = now.addingTimeInterval(2)
        let admission = now.addingTimeInterval(4)
        core.observeSession(request.providerSessionID, target: request.target, at: explicitStart)
        #expect(core.admit(request, now: admission, helperAlive: true))
        core.observeSession("stale", target: request.target, at: now.addingTimeInterval(1))
        #expect(core.outcome(request.identity)?.state == .pending)
        #expect(core.commit(request.identity, choice: .allow, now: admission, helperAlive: true) == .recorded)
        core.observeSession("replacement", target: request.target, at: now.addingTimeInterval(3))
        #expect(core.outcome(request.identity)?.state == .cancelled)
        #expect(core.claimDelivery(request.identity, now: admission, helperAlive: true) == nil)
    }

    @Test func progressBeforeIngressClosesOnlyTheMatchingLifetime() {
        let (core, request) = fixture()
        core.observeProgress(session: request.providerSessionID, target: request.target, at: now.addingTimeInterval(1))
        #expect(!core.admit(request, now: now.addingTimeInterval(2), helperAlive: true))
        let next = LocalPermissionRequest(
            target: request.target, providerSessionID: request.providerSessionID, invocationID: UUID(), toolUseID: nil,
            helperPID: 124, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(123), tool: "Bash", summary: "next"
        )
        #expect(core.admit(next, now: now.addingTimeInterval(3), helperAlive: true))
        core.observeProgress(session: next.providerSessionID, target: next.target, at: now.addingTimeInterval(1))
        #expect(core.outcome(next.identity)?.state == .pending)
    }

    @Test func unrelatedToolProgressCannotEraseSessionInvalidation() {
        let (core, request) = fixture()
        core.observeProgress(session: request.providerSessionID, target: request.target, at: now.addingTimeInterval(1))
        core.observeProgress(session: request.providerSessionID, target: request.target, at: now.addingTimeInterval(2), toolUseID: "other")
        #expect(!core.admit(request, now: now.addingTimeInterval(3), helperAlive: true))
    }

    @Test(arguments: [
        "echo " + String(repeating: "\u{2167}", count: 255) + "; touch /tmp/permission-review-example",
        "echo \u{2167}; touch /tmp/example",
        "echo e\u{301}",
        "echo hello\n touch /tmp/example",
        "echo\thello", "echo hello\r", "echo\u{0}hello",
        "echo\u{200B}hello", "echo\u{202E}hello", "echo\u{200D}hello",
        "echo\u{00A0}hello", " echo hello", "echo hello ",
        String(repeating: "a", count: 1024) + "; touch /tmp/example",
        String(repeating: "é", count: 513), "", "   ",
    ])
    func lossyOrOversizedConsentTextFallsThrough(summary: String) {
        let (core, original) = fixture()
        var request = original
        request.summary = summary
        #expect(LocalPermissionRequest.completeSummary(summary) == nil)
        #expect(!request.isValid(now: now))
        #expect(!core.admit(request, now: now, helperAlive: true))
    }

    @Test(arguments: ["echo hello; touch /tmp/example", String(repeating: "a", count: 1024), String(repeating: "é", count: 512)])
    func completeConsentTextPreservesEveryByte(summary: String) throws {
        let (core, original) = fixture()
        let represented = try #require(LocalPermissionRequest.completeSummary(summary))
        #expect(represented.utf8.elementsEqual(summary.utf8))
        var request = original
        request.summary = represented
        #expect(core.admit(request, now: now, helperAlive: true))
    }

    @Test(arguments: ["Ba\nsh", "Ｂash", " Bash", String(repeating: "a", count: 129)])
    func lossyOrOversizedToolTextFallsThrough(tool: String) {
        let (core, original) = fixture()
        var request = original
        request.tool = tool
        #expect(LocalPermissionRequest.completeSummary(tool, bytes: 128) == nil)
        #expect(!core.admit(request, now: now, helperAlive: true))
    }

    @Test(arguments: [false, true])
    func foreignSessionProgressCannotEraseCurrentCancellation(foreignArrivesFirst: Bool) {
        let (core, request) = fixture()
        if foreignArrivesFirst {
            core.observeProgress(session: "foreign", target: request.target, at: now.addingTimeInterval(2))
        }
        core.observeProgress(session: request.providerSessionID, target: request.target, at: now.addingTimeInterval(1))
        if !foreignArrivesFirst {
            core.observeProgress(session: "foreign", target: request.target, at: now.addingTimeInterval(2))
        }
        core.observeProgress(session: request.providerSessionID, target: request.target, at: now.addingTimeInterval(-1))
        #expect(!core.admit(request, now: now.addingTimeInterval(3), helperAlive: true))
        #expect(core.commit(request.identity, choice: .allow, now: now.addingTimeInterval(3), helperAlive: true) == nil)
    }

    @Test func genericProgressSaturationRefusesIngressUntilAffectedHooksExpire() {
        let (core, original) = fixture()
        for index in 0..<LocalPermissionDecisionCore.capacity {
            core.observeProgress(session: "foreign-\(index)", target: original.target, at: now.addingTimeInterval(1))
        }
        core.observeProgress(session: original.providerSessionID, target: original.target, at: now.addingTimeInterval(2))
        #expect(!core.admit(original, now: now.addingTimeInterval(3), helperAlive: true))
        let fresh = LocalPermissionRequest(
            target: original.target, providerSessionID: original.providerSessionID, invocationID: UUID(), toolUseID: nil,
            helperPID: 123, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(124), tool: "Bash", summary: "fresh"
        )
        #expect(!core.admit(fresh, now: now.addingTimeInterval(4), helperAlive: true))
        let recovered = LocalPermissionRequest(
            target: original.target, providerSessionID: original.providerSessionID, invocationID: UUID(), toolUseID: nil,
            helperPID: 123, helperStartMicroseconds: 1, expiresAt: now.addingTimeInterval(248), tool: "Bash", summary: "recovered"
        )
        #expect(core.admit(recovered, now: now.addingTimeInterval(128), helperAlive: true))
    }

}
