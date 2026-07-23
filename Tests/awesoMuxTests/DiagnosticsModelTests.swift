import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@MainActor
private func controlledTiming(
    clock: TestClock = TestClock(),
    scheduler: TestScheduler
) -> DiagnosticsTiming {
    DiagnosticsTiming(
        wallNow: { clock.now },
        monotonicNow: { .zero },
        sleepUntil: { deadline, _ in
            await scheduler.wait(for: deadline)
            try Task.checkCancellation()
        }
    )
}

@MainActor
@Suite("Diagnostics model")
struct DiagnosticsModelTests {
    @Test("failed refresh retains the last good snapshot")
    func failedRefreshRetainsLastGoodSnapshot() async throws {
        let store = SessionStore()
        let recorder = LocalDiagnosticEventRecorder()
        var callCount = 0
        let expected = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let model = DiagnosticsModel(sessionStore: store, eventRecorder: recorder) { _, _, _ in
            callCount += 1
            return callCount == 1
                ? DiagnosticsCaptureResult(snapshot: expected, discoveredDaemons: [])
                : nil
        }

        await model.refresh()
        let firstCheckedAt = try #require(model.presentation.checkedAt)
        #expect(model.presentation.processSnapshot == expected)

        await model.refresh()
        #expect(model.presentation.processSnapshot == expected)
        #expect(model.presentation.checkedAt == firstCheckedAt)
        #expect(model.refreshState == .failed(lastSuccess: firstCheckedAt))
        #expect(model.presentation.events.warningCount == 1)
    }

    @Test("failed refresh retains the last published background sample")
    func failedRefreshKeepsPresentationAndFreshnessConsistent() async throws {
        let store = SessionStore()
        let recorder = LocalDiagnosticEventRecorder()
        let first = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let background = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 84,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var captures: [DiagnosticsProcessSnapshot?] = [first, background, nil]
        let model = DiagnosticsModel(sessionStore: store, eventRecorder: recorder) { _, _, _ in
            captures.removeFirst().map {
                DiagnosticsCaptureResult(snapshot: $0, discoveredDaemons: [])
            }
        }

        await model.refresh()
        await model.sampleOnce(at: background.collectedAt)
        let published = model.presentation
        await model.refresh()

        #expect(model.presentation.processSnapshot == published.processSnapshot)
        #expect(model.presentation.history == published.history)
        #expect(model.presentation.checkedAt == published.checkedAt)
        #expect(model.presentation.events.warningCount == 1)
    }

    @Test("successful sample clears a prior failed refresh state when daemons are listed")
    func successfulSampleClearsFailedRefreshState() async throws {
        let first = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let recovered = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 30),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var captures: [DiagnosticsProcessSnapshot?] = [first, nil, recovered]
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, _ in
            captures.removeFirst().map {
                DiagnosticsCaptureResult(snapshot: $0, discoveredDaemons: [])
            }
        }

        await model.refresh()
        let firstCheckedAt = try #require(model.presentation.checkedAt)
        await model.refresh()
        #expect(model.refreshState == .failed(lastSuccess: firstCheckedAt))

        await model.sampleOnce(at: recovered.collectedAt)

        #expect(model.refreshState == .idle)
        #expect(model.presentation.processSnapshot == recovered)
        #expect(model.presentation.checkedAt == recovered.collectedAt)
    }

    @Test("successful sample with unavailable daemon list lands on partial after failure")
    func successfulSampleWithUnavailableListSetsPartial() async throws {
        let first = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        let recovered = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 30),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        var captures: [DiagnosticsProcessSnapshot?] = [first, nil, recovered]
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, _ in
            captures.removeFirst().map {
                DiagnosticsCaptureResult(snapshot: $0, discoveredDaemons: nil)
            }
        }

        await model.refresh()
        #expect(model.refreshState == .partial)
        let partialCheckedAt = try #require(model.presentation.checkedAt)
        await model.refresh()
        #expect(model.refreshState == .failed(lastSuccess: partialCheckedAt))

        await model.sampleOnce(at: recovered.collectedAt)

        #expect(model.refreshState == .partial)
        #expect(model.presentation.processSnapshot == recovered)
    }

    @Test("rediscovery failure while idle raises partial")
    func rediscoveryFailureSetsPartial() async {
        let ok = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let degraded = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            if purpose.isRefresh {
                return DiagnosticsCaptureResult(snapshot: ok, discoveredDaemons: [])
            }
            if case let .sample(_, rediscover, _) = purpose, rediscover {
                return DiagnosticsCaptureResult(snapshot: degraded, discoveredDaemons: nil)
            }
            return DiagnosticsCaptureResult(snapshot: ok, discoveredDaemons: nil)
        }

        await model.refresh()
        #expect(model.refreshState == .idle)
        for _ in 0..<5 {
            await model.sampleOnce()
        }

        #expect(model.refreshState == .partial)
    }

    @Test("failed sample republishes pruned events without inventing process data")
    func failedSampleRepublishesEventsOnly() async {
        let retention: TimeInterval = 30
        let recorder = LocalDiagnosticEventRecorder(retention: retention, maximumEntries: 10)
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var callCount = 0
        let eventTime = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(eventTime)
        let scheduler = TestScheduler()
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: recorder,
            timing: controlledTiming(clock: clock, scheduler: scheduler)
        ) { _, _, _ in
            callCount += 1
            return callCount == 1
                ? DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: [])
                : nil
        }
        recorder.record(.terminalReady, at: eventTime)

        await model.refresh()
        #expect(model.presentation.events.events.count == 1)
        #expect(model.presentation.processSnapshot == snapshot)

        await model.sampleOnce(at: eventTime.addingTimeInterval(retention + 5))

        #expect(model.presentation.processSnapshot == snapshot)
        #expect(model.presentation.events.events.isEmpty)
        #expect(model.presentation.checkedAt != nil)
    }

    @Test("partial daemon discovery publishes process data and its status")
    func partialDaemonDiscovery() async {
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, _ in
            DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: nil)
        }

        await model.refresh()

        #expect(model.presentation.processSnapshot == snapshot)
        #expect(model.refreshState == .partial)
    }

    @Test("partial refresh keeps known daemon groups via fallback purpose")
    func partialRefreshPassesFallbackDaemons() async throws {
        let sessionID = try #require(TerminalSessionID(rawValue: "11111111-1111-1111-1111-111111111111"))
        let daemon = LiveDaemon(id: sessionID, pid: 200, createdEpoch: 1, clients: 1)
        let withGroups = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 100,
            daemonListAvailable: true,
            appProcesses: [],
            groups: [
                DiagnosticsProcessGroup(
                    sessionID: sessionID,
                    title: "Feature · Agent",
                    isSelected: true,
                    processes: [
                        DiagnosticsProcess(
                            pid: 200,
                            parentPID: 1,
                            cpuPercent: 1,
                            residentBytes: 1_024,
                            executablePath: "/usr/local/bin/amx",
                            kind: .daemon
                        )
                    ]
                )
            ]
        )
        let partial = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 100,
            daemonListAvailable: false,
            appProcesses: [],
            groups: withGroups.groups
        )
        var purposes: [DiagnosticsCapturePurpose] = []
        var callCount = 0
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            purposes.append(purpose)
            callCount += 1
            if callCount == 1 {
                return DiagnosticsCaptureResult(snapshot: withGroups, discoveredDaemons: [daemon])
            }
            return DiagnosticsCaptureResult(snapshot: partial, discoveredDaemons: nil)
        }

        await model.refresh()
        await model.refresh()

        #expect(purposes[1] == .refresh(fallbackDaemons: [daemon]))
        #expect(model.refreshState == .partial)
        #expect(model.presentation.processSnapshot?.groups.count == 1)
        #expect(model.presentation.processSnapshot?.daemonListAvailable == false)
    }

    @Test("stale sample does not overwrite a newer refresh after join")
    func staleSampleDoesNotOverwriteNewerRefresh() async {
        let sampleSnapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        let refreshSnapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var continuation: CheckedContinuation<DiagnosticsCaptureResult?, Never>?
        var callCount = 0
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            callCount += 1
            if callCount == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            #expect(purpose.isRefresh)
            return DiagnosticsCaptureResult(snapshot: refreshSnapshot, discoveredDaemons: [])
        }

        async let sample: Void = model.sampleOnce()
        while continuation == nil { await Task.yield() }
        async let refresh: Void = model.refresh()
        await Task.yield()
        continuation?.resume(
            returning: DiagnosticsCaptureResult(
                snapshot: sampleSnapshot,
                discoveredDaemons: nil
            ))
        await sample
        await refresh

        #expect(model.presentation.processSnapshot == refreshSnapshot)
        #expect(
            model.presentation.checkedAt == refreshSnapshot.collectedAt
                || model.refreshState == .idle)
        #expect(model.refreshState == .idle)
        #expect(model.presentation.processSnapshot?.daemonListAvailable == true)
    }

    @Test("manual refresh follows an in-flight sample with daemon discovery")
    func refreshAfterInFlightSampleDiscoversDaemons() async {
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var continuation: CheckedContinuation<DiagnosticsCaptureResult?, Never>?
        var purposes: [DiagnosticsCapturePurpose] = []
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            purposes.append(purpose)
            if purposes.count == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: [])
        }

        async let sample: Void = model.sampleOnce()
        while continuation == nil { await Task.yield() }
        async let refresh: Void = model.refresh()
        await Task.yield()
        continuation?.resume(
            returning: DiagnosticsCaptureResult(
                snapshot: snapshot,
                discoveredDaemons: nil
            ))
        await sample
        await refresh

        #expect(
            purposes == [
                .sample(knownDaemons: [], rediscoverDaemons: false, daemonListAvailable: true),
                .refresh(fallbackDaemons: []),
            ])
        #expect(model.presentation.processSnapshot == snapshot)
    }

    @Test("background samples reuse daemons discovered by manual refresh")
    func backgroundSamplesReuseDiscoveredDaemons() async {
        let daemon = LiveDaemon(
            id: TerminalSessionID(rawValue: "session")!,
            pid: 42,
            createdEpoch: 1,
            clients: 1
        )
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var purposes: [DiagnosticsCapturePurpose] = []
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            purposes.append(purpose)
            return DiagnosticsCaptureResult(
                snapshot: snapshot,
                discoveredDaemons: purpose.isRefresh ? [daemon] : nil
            )
        }

        await model.refresh()
        await model.sampleOnce()

        #expect(
            purposes == [
                .refresh(fallbackDaemons: []),
                .sample(knownDaemons: [daemon], rediscoverDaemons: false, daemonListAvailable: true),
            ])
    }

    @Test("every fifth sample requests daemon rediscovery")
    func fifthSampleRediscoverDaemons() async {
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var rediscoverFlags: [Bool] = []
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            if case let .sample(_, rediscover, _) = purpose {
                rediscoverFlags.append(rediscover)
            }
            return DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: purpose.isRefresh ? [] : nil)
        }

        await model.refresh()
        for _ in 0..<5 {
            await model.sampleOnce()
        }

        #expect(rediscoverFlags == [false, false, false, false, true])
    }

    @Test("successful rediscovery clears partial refresh state")
    func rediscoveryClearsPartialState() async {
        let partial = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: false,
            appProcesses: [],
            groups: []
        )
        let recovered = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var callCount = 0
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder()
        ) { _, _, purpose in
            callCount += 1
            if purpose.isRefresh {
                return DiagnosticsCaptureResult(snapshot: partial, discoveredDaemons: nil)
            }
            if case let .sample(_, rediscover, _) = purpose, rediscover {
                return DiagnosticsCaptureResult(snapshot: recovered, discoveredDaemons: [])
            }
            return DiagnosticsCaptureResult(snapshot: partial, discoveredDaemons: nil)
        }

        await model.refresh()
        #expect(model.refreshState == .partial)
        for _ in 0..<5 {
            await model.sampleOnce()
        }

        #expect(model.refreshState == .idle)
        #expect(model.presentation.processSnapshot?.daemonListAvailable == true)
    }

    @Test("startSampling publishes launch events without a process snapshot")
    func startSamplingPublishesEventsOnly() {
        let recorder = LocalDiagnosticEventRecorder()
        let now = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(now)
        let scheduler = TestScheduler()
        recorder.record(.terminalReady, at: now.addingTimeInterval(-2))
        recorder.record(.restoreSanitized, at: now.addingTimeInterval(-1))
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: recorder,
            timing: controlledTiming(clock: clock, scheduler: scheduler)
        ) { _, _, _ in nil }

        model.startSampling()

        #expect(model.presentation.processSnapshot == nil)
        #expect(model.presentation.events.events.count == 2)
        #expect(model.presentation.checkedAt == nil)
        model.stopSampling()
        scheduler.advanceOneCycle()
    }

    @Test("pane-visible maintenance prunes events before the first process refresh")
    func maintenancePrunesEventsBeforeFirstRefresh() async {
        let retention: TimeInterval = 30
        let recorder = LocalDiagnosticEventRecorder(retention: retention, maximumEntries: 10)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(t0)
        let scheduler = TestScheduler()
        recorder.record(.terminalReady, at: t0)
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: recorder,
            timing: controlledTiming(clock: clock, scheduler: scheduler)
        ) { _, _, _ in nil }

        model.startSampling()
        #expect(model.presentation.events.events.count == 1)

        #expect(await waitUntil { scheduler.sleeperCount == 1 })
        clock.advance(by: retention + 1)
        scheduler.advanceOneCycle()
        #expect(await waitUntil { model.presentation.events.events.isEmpty })
        #expect(model.presentation.events.events.isEmpty)
        #expect(model.presentation.processSnapshot == nil)
        model.stopSampling()
        scheduler.advanceOneCycle()
    }

    @Test("sampling task does not retain the model")
    func samplingTaskDoesNotRetainModel() async {
        weak var weakModel: DiagnosticsModel?
        do {
            let model = DiagnosticsModel(
                sessionStore: SessionStore(),
                eventRecorder: LocalDiagnosticEventRecorder(),
                sampleInterval: .seconds(60)
            ) { _, _, _ in nil }
            weakModel = model
            model.startSampling()
        }
        for _ in 0..<10 where weakModel != nil {
            await Task.yield()
        }

        #expect(weakModel == nil)
    }

    @Test("maintenance keeps cadence, tolerance, missed ticks, and cancellation")
    func maintenanceSchedulingPolicy() async {
        let scheduler = TestScheduler()
        let monotonicClock = TestClock(Date(timeIntervalSince1970: 10))
        var scheduled: [(deadline: Duration, tolerance: Duration)] = []
        let timing = DiagnosticsTiming(
            wallNow: { Date(timeIntervalSince1970: 1_000) },
            monotonicNow: { .seconds(monotonicClock.now.timeIntervalSince1970) },
            sleepUntil: { deadline, tolerance in
                scheduled.append((deadline, tolerance))
                await scheduler.wait(for: deadline)
                try Task.checkCancellation()
            }
        )
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder(),
            timing: timing,
            sampleInterval: .seconds(30),
            sampleTolerance: .seconds(3)
        ) { _, _, _ in nil }

        model.startSampling()
        #expect(await waitUntil { scheduled.count == 1 })
        #expect(scheduled[0].deadline == .seconds(40))
        #expect(scheduled[0].tolerance == .seconds(3))

        monotonicClock.set(Date(timeIntervalSince1970: 125))
        scheduler.advanceOneCycle()
        #expect(await waitUntil { scheduled.count == 2 })
        #expect(scheduled[1].deadline == .seconds(130))
        #expect(scheduled[1].tolerance == .seconds(3))

        model.stopSampling()
        scheduler.advanceOneCycle()
        await drainMainQueue()
        #expect(scheduled.count == 2)
    }

    @Test("background sampling removes expired diagnostic events")
    func backgroundSamplingRemovesExpiredEvents() async {
        let recorder = LocalDiagnosticEventRecorder(retention: 30, maximumEntries: 10)
        recorder.record(.terminalReady, at: Date(timeIntervalSince1970: 0))
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: recorder
        ) { _, _, _ in nil }

        await model.sampleOnce(at: Date(timeIntervalSince1970: 40))

        #expect(recorder.snapshot(now: Date(timeIntervalSince1970: 0)).events.isEmpty)
    }

    @Test("visible sampling waits for the first manual refresh")
    func visibleSamplingWaitsForManualRefresh() async {
        var callCount = 0
        let scheduler = TestScheduler()
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder(),
            timing: controlledTiming(scheduler: scheduler)
        ) { _, _, _ in
            callCount += 1
            return DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: [])
        }

        model.startSampling()
        #expect(await waitUntil { scheduler.sleepCallCount == 1 })
        #expect(callCount == 0)

        await model.refresh()
        #expect(callCount == 1)
        #expect(await waitUntil { scheduler.sleepCallCount == 2 })
        scheduler.advanceOneCycle()
        #expect(await waitUntil { callCount == 2 })
        model.stopSampling()
        scheduler.advanceOneCycle()
    }

    @Test("stopping visible sampling prevents later captures")
    func stoppingVisibleSamplingPreventsLaterCaptures() async {
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var callCount = 0
        let scheduler = TestScheduler()
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder(),
            timing: controlledTiming(scheduler: scheduler)
        ) { _, _, _ in
            callCount += 1
            return DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: [])
        }

        model.startSampling()
        await model.refresh()
        #expect(await waitUntil { scheduler.sleepCallCount == 2 })
        model.stopSampling()
        scheduler.advanceOneCycle()
        await drainMainQueue()

        #expect(callCount == 1)
    }

    @Test("stopping visible sampling cancels an in-flight timed capture")
    func stoppingVisibleSamplingCancelsInFlightCapture() async {
        let snapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 10),
            appPID: 42,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        let canceledSnapshot = DiagnosticsProcessSnapshot(
            collectedAt: Date(timeIntervalSince1970: 20),
            appPID: 84,
            daemonListAvailable: true,
            appProcesses: [],
            groups: []
        )
        var callCount = 0
        var sampleWasCancelled = false
        let scheduler = TestScheduler()
        let captureGate = AsyncGate()
        let model = DiagnosticsModel(
            sessionStore: SessionStore(),
            eventRecorder: LocalDiagnosticEventRecorder(),
            timing: controlledTiming(scheduler: scheduler)
        ) { _, _, _ in
            callCount += 1
            if callCount == 1 {
                return DiagnosticsCaptureResult(snapshot: snapshot, discoveredDaemons: [])
            }
            await captureGate.wait()
            sampleWasCancelled = Task.isCancelled
            return DiagnosticsCaptureResult(snapshot: canceledSnapshot, discoveredDaemons: [])
        }

        model.startSampling()
        await model.refresh()
        #expect(await waitUntil { scheduler.sleepCallCount == 2 })
        scheduler.advanceOneCycle()
        #expect(await waitUntil { callCount == 2 })
        #expect(callCount == 2)

        model.stopSampling()
        captureGate.open()
        #expect(await waitUntil { sampleWasCancelled })

        #expect(sampleWasCancelled)
        #expect(model.presentation.processSnapshot == snapshot)
        #expect(model.presentation.history.samples.count == 1)
    }
}
