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

    // One authenticated device must not monopolize the shared retry cache.
    @Test(arguments: [false, true]) func retryQuotaIsPerDeviceAndReclaimsExpiredTuples(unknownIdentity: Bool) {
        var instant = ContinuousClock.now
        let core = LocalPermissionDecisionCore(monotonicNow: { instant })
        let (_, request) = fixture.fixture()
        core.install(request.target)
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        var cachedIdentity = request.identity
        if unknownIdentity {
            cachedIdentity.revision += 1
        } else {
            _ = core.commit(request.identity, choice: .deny, now: fixture.now, helperAlive: true)
        }
        let deviceA = UUID(), deviceB = UUID(), firstRetry = UUID()
        let first = core.commitRemote(
            cachedIdentity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: firstRetry,
            now: fixture.now, helperAlive: true)
        #expect(first.result == (unknownIdentity ? .unknown : .alreadyAnswered))
        for _ in 1..<LocalPermissionDecisionCore.retryCapacityPerDevice {
            #expect(
                core.commitRemote(
                    cachedIdentity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: UUID(),
                    now: fixture.now, helperAlive: true
                ).result == first.result)
        }
        #expect(
            core.commitRemote(
                cachedIdentity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: UUID(),
                now: fixture.now, helperAlive: true
            ).result == .capacityExceeded)
        #expect(
            core.commitRemote(
                cachedIdentity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: firstRetry,
                now: fixture.now, helperAlive: true) == first)
        #expect(LocalPermissionDecisionCore.retryCapacityPerDevice < LocalPermissionDecisionCore.retryCapacity)
        let newRequest = LocalPermissionRequest(
            target: request.target, providerSessionID: request.providerSessionID,
            invocationID: UUID(), toolUseID: nil, helperPID: request.helperPID, helperStartMicroseconds: request.helperStartMicroseconds,
            expiresAt: request.expiresAt, tool: "Bash", summary: "second request")
        #expect(core.admit(newRequest, now: fixture.now, helperAlive: true))
        #expect(
            core.commitRemote(
                newRequest.identity, choice: .allow, deviceID: deviceB, deviceName: "B", retryID: UUID(),
                now: fixture.now, helperAlive: true
            ).result == .recorded)
        let reclaimedAt = request.expiresAt.addingTimeInterval(600)
        instant = instant.advanced(by: .seconds(720))
        #expect(
            core.commitRemote(
                cachedIdentity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: UUID(),
                now: reclaimedAt, helperAlive: true
            ).result == .unknown)
    }

    // Replacing an escaped file must only remove choice authority for the exact
    // invocation. A generic overwriting writer could replay/substitute choices.
    @Test func terminalFileReplacementCannotChangeIdentityOrPublishChoice() throws {
        let (_, request) = fixture.fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-decision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("decision.json")
        let original = LocalPermissionOutcome(identity: request.identity, state: .delivering, choice: .allow)
        #expect(LocalPermissionFiles.write(original, at: file))
        #expect(!LocalPermissionFiles.replaceWithTerminalOutcome(original, at: file))
        let foreign = LocalPermissionIdentity(
            target: request.target, providerSessionID: request.providerSessionID,
            invocationID: UUID(), revision: 1)
        #expect(!LocalPermissionFiles.replaceWithTerminalOutcome(.init(identity: foreign, state: .unknown), at: file))
        #expect(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: file) == original)
        let terminal = LocalPermissionOutcome(identity: request.identity, state: .unknown)
        #expect(LocalPermissionFiles.replaceWithTerminalOutcome(terminal, at: file))
        #expect(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: file) == terminal)
        #expect(
            !LocalPermissionFiles.replaceWithTerminalOutcome(.init(identity: request.identity, state: .unknown, choice: .deny), at: file))
        #expect(LocalPermissionFiles.read(LocalPermissionOutcome.self, at: file) == terminal)
    }

    // Positive receipts must release per-device capacity after the remaining
    // hook lifetime plus ten minutes even when Date moves backward.
    @Test(arguments: [0, 50]) func positiveRetryRetentionUsesMonotonicExpiry(createdAfterSeconds: Int) {
        let start = ContinuousClock.now
        var instant = start
        let core = LocalPermissionDecisionCore(monotonicNow: { instant })
        let (_, request) = fixture.fixture()
        core.install(request.target)
        #expect(core.admit(request, now: fixture.now, helperAlive: true))
        instant = start.advanced(by: .seconds(createdAfterSeconds))
        let createdAt = fixture.now.addingTimeInterval(Double(createdAfterSeconds))
        let deviceA = UUID(), deviceB = UUID(), firstRetry = UUID(), retryB = UUID()
        let first = core.commitRemote(
            request.identity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: firstRetry,
            now: createdAt, helperAlive: true)
        #expect(first.result == .recorded)
        #expect(core.claimDelivery(request.identity, now: createdAt, helperAlive: true) == .allow)
        core.acknowledge(request.identity)
        for _ in 1..<LocalPermissionDecisionCore.retryCapacityPerDevice {
            #expect(
                core.commitRemote(
                    request.identity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: UUID(),
                    now: createdAt, helperAlive: true
                ).result == .alreadyAnswered)
        }
        let other = LocalPermissionRequest(
            target: request.target, providerSessionID: request.providerSessionID,
            invocationID: UUID(), toolUseID: nil, helperPID: request.helperPID, helperStartMicroseconds: request.helperStartMicroseconds,
            expiresAt: request.expiresAt, tool: "Bash", summary: "other device")
        #expect(core.admit(other, now: createdAt, helperAlive: true))
        let firstB = core.commitRemote(
            other.identity, choice: .deny, deviceID: deviceB, deviceName: "B", retryID: retryB,
            now: createdAt, helperAlive: true)
        #expect(firstB.result == .recorded)
        instant = start.advanced(by: .seconds(720) - .milliseconds(1))
        let rolledBackWall = fixture.now.addingTimeInterval(20)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: firstRetry,
                now: rolledBackWall, helperAlive: true) == first)
        #expect(
            core.commitRemote(
                other.identity, choice: .deny, deviceID: deviceB, deviceName: "B", retryID: retryB,
                now: rolledBackWall, helperAlive: true) == firstB)
        #expect(
            core.commitRemote(
                request.identity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: UUID(),
                now: rolledBackWall, helperAlive: true
            ).result == .capacityExceeded)
        instant = start.advanced(by: .seconds(720))
        let afterExpiry = core.commitRemote(
            request.identity, choice: .allow, deviceID: deviceA, deviceName: "A", retryID: firstRetry,
            now: rolledBackWall, helperAlive: true)
        #expect(afterExpiry.result == .alreadyAnswered)
        #expect(afterExpiry.outcome?.state == .delivered)
        #expect(afterExpiry.outcome?.choice == .allow)
        #expect(core.claimDelivery(request.identity, now: rolledBackWall, helperAlive: true) == nil)
        #expect(core.outcome(request.identity)?.state == .delivered)
    }

}
