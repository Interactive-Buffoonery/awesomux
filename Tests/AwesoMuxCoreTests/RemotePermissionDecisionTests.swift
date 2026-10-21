import Foundation
import Testing
@testable import AwesoMuxCore

// Isolation is necessary for atomic time/retry boundaries that the network
// fixture cannot schedule precisely. Remote expiry must leave Mac authority live;
// lost replies, conflicting retries and competing sources must never recommit.
@Suite @MainActor struct RemotePermissionDecisionTests {
    let fixture = LocalPermissionDecisionCoreTests()
    @Test func remoteExpiryLeavesMacPending() {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        let receipt = core.commitRemote(
            request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone",
            retryID: UUID(), now: fixture.now.addingTimeInterval(60), helperAlive: true)
        #expect(receipt.result == .expired)
        #expect(core.outcome(request.identity)?.state == .pending)
        #expect(core.commit(request.identity, choice: .deny, now: fixture.now.addingTimeInterval(61), helperAlive: true) == .recorded)
    }
    @Test func retryIsStableAndConflictsCannotChangeWinner() {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        let device = UUID(), retry = UUID()
        let first = core.commitRemote(
            request.identity, choice: .allow, deviceID: device, deviceName: "Phone",
            retryID: retry, now: fixture.now, helperAlive: true)
        #expect(first.result == .recorded)
        #expect(core.claimDelivery(request.identity, now: fixture.now, helperAlive: true) == .allow)
        core.acknowledge(request.identity)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: device, deviceName: "Phone",
                retryID: retry, now: fixture.now.addingTimeInterval(90), helperAlive: true) == first)
        #expect(
            core.commitRemote(
                request.identity, choice: .deny, deviceID: device, deviceName: "Phone",
                retryID: retry, now: fixture.now, helperAlive: true
            ).result == .retryConflict)
        #expect(core.outcome(request.identity)?.choice == .allow)
        #expect(core.claimDelivery(request.identity, now: fixture.now, helperAlive: true) == nil)
    }
    @Test func macWinnerCannotBeOverwritten() {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        _ = core.commit(request.identity, choice: .deny, now: fixture.now, helperAlive: true)
        let receipt = core.commitRemote(
            request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone",
            retryID: UUID(), now: fixture.now, helperAlive: true)
        #expect(receipt.result == .alreadyAnswered)
        #expect(receipt.outcome?.choice == .deny)
        #expect(receipt.outcome?.source == .mac)
    }
    @Test func boundedRetryRetentionCannotReopenEvictedInvocation() {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        for _ in 0..<LocalPermissionDecisionCore.retryCapacity {
            let receipt = core.commitRemote(
                request.identity, choice: .deny, deviceID: UUID(), deviceName: "Phone",
                retryID: UUID(), now: fixture.now, helperAlive: true)
            #expect(receipt.result == .recorded || receipt.result == .alreadyAnswered)
        }
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone",
                retryID: UUID(), now: fixture.now, helperAlive: true
            ).result == .capacityExceeded)
        let later = request.expiresAt.addingTimeInterval(601)
        core.sweep(now: later)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone",
                retryID: UUID(), now: later, helperAlive: true
            ).result == .unknown)
        #expect(!core.admit(request, now: fixture.now, helperAlive: true))
    }

    @Test(arguments: [false, true]) func revokedRemoteDeliveryDistinguishesEscapedOutput(attempted: Bool) {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        _ = core.commitRemote(
            request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone", retryID: UUID(),
            now: fixture.now, helperAlive: true)
        #expect(core.claimDelivery(request.identity, now: fixture.now, helperAlive: true) == .allow)
        if attempted { core.markOutputAttempted(request.identity) }
        core.cancel(request.identity)
        #expect(core.outcome(request.identity)?.state == (attempted ? .unknown : .cancelled))
    }

    @Test func futureHelperClockCannotExtendRemoteWindow() {
        let (core, request) = fixture.fixture()
        let admittedAt = fixture.now.addingTimeInterval(-5)
        #expect(core.admit(request, now: admittedAt, helperAlive: true))
        #expect(core.remoteExpiry(request.identity) == admittedAt.addingTimeInterval(60))
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone", retryID: UUID(),
                now: admittedAt.addingTimeInterval(60), helperAlive: true
            ).result == .expired)
        #expect(core.outcome(request.identity)?.state == .pending)
    }

    // Wall-clock rollback must not extend either the 60-second window or
    // a shorter remaining hook window. ContinuousClock includes sleep time.
    @Test(arguments: [false, true]) func rollbackCannotExtendRemoteDeadline(shortRemainingWindow: Bool) {
        var instant = ContinuousClock.now
        let core = LocalPermissionDecisionCore(monotonicNow: { instant })
        let (_, request) = fixture.fixture()
        core.install(request.target)
        let admittedAt = fixture.now.addingTimeInterval(shortRemainingWindow ? 50 : 0)
        #expect(core.admit(request, now: admittedAt, helperAlive: true))
        let wireDeadline = core.remoteExpiry(request.identity)
        #expect(wireDeadline == fixture.now.addingTimeInterval(60))
        instant = instant.advanced(by: .seconds(shortRemainingWindow ? 11 : 70))
        let rolledBackWall = admittedAt.addingTimeInterval(shortRemainingWindow ? 5 : 40)
        #expect(core.remoteExpiry(request.identity) == nil)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: UUID(), deviceName: "Phone", retryID: UUID(),
                now: rolledBackWall, helperAlive: true
            ).result == .expired)
        #expect(core.outcome(request.identity)?.state == .pending)
        #expect(core.commit(request.identity, choice: .deny, now: rolledBackWall, helperAlive: true) == .recorded)
    }

    @Test func unknownRetryBindsExactIdentityAndChoice() {
        let (core, request) = fixture.fixture()
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        var stale = request.identity
        stale.revision += 1
        let device = UUID(), retry = UUID()
        let first = core.commitRemote(
            stale, choice: .allow, deviceID: device, deviceName: "Phone", retryID: retry,
            now: fixture.now, helperAlive: true)
        #expect(first.result == .unknown)
        #expect(
            core.commitRemote(
                stale, choice: .allow, deviceID: device, deviceName: "Phone", retryID: retry,
                now: fixture.now, helperAlive: true) == first)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: device, deviceName: "Phone", retryID: retry,
                now: fixture.now, helperAlive: true
            ).result == .retryConflict)
        #expect(
            core.commitRemote(
                stale, choice: .deny, deviceID: device, deviceName: "Phone", retryID: retry,
                now: fixture.now, helperAlive: true
            ).result == .retryConflict)
        #expect(core.outcome(request.identity)?.state == .pending)
    }

    @Test func unknownRetryCapacityExpiresAfterTenMonotonicMinutes() {
        var instant = ContinuousClock.now
        let core = LocalPermissionDecisionCore(monotonicNow: { instant })
        let (_, request) = fixture.fixture()
        core.install(request.target)
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        var stale = request.identity
        stale.revision += 1
        for _ in 0..<LocalPermissionDecisionCore.retryCapacity {
            #expect(
                core.commitRemote(
                    stale, choice: .allow, deviceID: UUID(), deviceName: "Phone", retryID: UUID(),
                    now: fixture.now, helperAlive: true
                ).result == .unknown)
        }
        let device = UUID(), retry = UUID()
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: device, deviceName: "Phone", retryID: retry,
                now: fixture.now, helperAlive: true
            ).result == .capacityExceeded)
        instant = instant.advanced(by: .seconds(600))
        // A rolled-back Date must not keep negative cache capacity occupied.
        #expect(
            core.commitRemote(
                stale, choice: .allow, deviceID: device, deviceName: "Phone", retryID: retry,
                now: fixture.now.addingTimeInterval(-30), helperAlive: true
            ).result == .unknown)
    }

}
