import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

/// Zero-delay seam for tests that care about ordering, not timing.
struct ImmediateDelayClock: AgentIntegrationSettingsSleeping {
    func delay(for duration: Duration) async throws {}
}

/// One-shot resumption gate that can also be fired by cancellation, so a
/// parked wait never outlives its timeout.
final class WaitHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let pending = continuation
        continuation = nil
        fired = true
        lock.unlock()
        pending?.resume()
    }
}

/// Scripted probe service: records call counts per provider, optionally holds
/// calls until released, and serves per-provider snapshots.
final class SpyAgentIntegrationProbeService: AgentIntegrationProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [AgentIntegrationInstallProvider: Int] = [:]
    private var results: [AgentIntegrationInstallProvider: AgentIntegrationProviderProbe] = [:]
    /// Per-call scripts consumed in call-start order regardless of completion
    /// order, so an older held call can be given a different outcome than a
    /// newer one.
    private var scripts: [AgentIntegrationInstallProvider: [AgentIntegrationProviderProbe]] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var shouldHold = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var callCounts: [AgentIntegrationInstallProvider: Int] {
        withLock { counts }
    }

    func setResult(_ result: AgentIntegrationProviderProbe, for provider: AgentIntegrationInstallProvider) {
        withLock { results[provider] = result }
    }

    func script(_ sequence: [AgentIntegrationProviderProbe], for provider: AgentIntegrationInstallProvider) {
        withLock { scripts[provider] = sequence }
    }

    func holdCalls(_ hold: Bool) {
        withLock { shouldHold = hold }
    }

    func releaseHeldCalls() {
        let waiting = withLock { () -> [CheckedContinuation<Void, Never>] in
            let copy = held
            held.removeAll()
            shouldHold = false
            return copy
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    func probe(provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup) async
        -> AgentIntegrationProviderProbe
    {
        // Consume the per-call script at call START so completion order cannot
        // reshuffle which outcome belongs to which probe.
        let scripted: AgentIntegrationProviderProbe? = withLock {
            counts[provider, default: 0] += 1
            notifyWaiters()
            guard var queue = scripts[provider], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            scripts[provider] = queue
            return next
        }

        while withLock({ shouldHold }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.withLock { self.held.append(continuation) }
            }
        }

        return scripted ?? withLock { results[provider] ?? Self.emptyProbe }
    }

    /// Suspends until `provider` has been probed at least `count` times, or
    /// times out. Cancellation-aware: a timed-out wait resumes its parked
    /// continuation instead of wedging the enclosing task group forever.
    func waitForCallCount(provider: AgentIntegrationInstallProvider, atLeast count: Int) async {
        let handle = WaitHandle()
        let waiter = Task {
            await self.waitContinuation(provider: provider, count: count, handle: handle)
        }
        let watchdog = Task {
            try? await ContinuousClock().sleep(for: .seconds(5))
            waiter.cancel()
        }
        await waiter.value
        watchdog.cancel()
        withLock { waiters.removeAll { $0.handle === handle } }
    }

    private func waitContinuation(
        provider: AgentIntegrationInstallProvider,
        count: Int,
        handle: WaitHandle
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = self.withLock { () -> Bool in
                    if (self.counts[provider] ?? 0) >= count {
                        return true
                    }
                    self.waiters.append(
                        Waiter(provider: provider, count: count, handle: handle))
                    return false
                }
                if resumeNow {
                    continuation.resume()
                } else {
                    handle.register(continuation)
                }
            }
        } onCancel: {
            handle.fire()
        }
    }

    private struct Waiter {
        let provider: AgentIntegrationInstallProvider
        let count: Int
        let handle: WaitHandle
    }

    private var waiters: [Waiter] = []

    private func notifyWaiters() {
        var stillWaiting: [Waiter] = []
        for waiter in waiters {
            if (counts[waiter.provider] ?? 0) >= waiter.count {
                waiter.handle.fire()
            } else {
                stillWaiting.append(waiter)
            }
        }
        waiters = stillWaiting
    }

    static let emptyProbe = AgentIntegrationProviderProbe(
        manifest: .missing,
        installedExists: false,
        templatePath: "/tmp/template",
        renderedPath: "/tmp/rendered",
        globalInstallPath: "/tmp/destination",
        binaryValidation: .unset("/usr/bin/example"),
        configHomeValidation: .unset("/tmp/config"),
        templateExists: true,
        renderedExists: false,
        installedContentDiffersFromTemplate: false
    )
}

@Suite("Agent integration settings card model", .serialized)
@MainActor
struct AgentIntegrationSettingsCardModelTests {
    @Test("placeholder precedes first authoritative probe and locks install")
    func placeholderPrecedesFirstAuthoritativeProbe() async throws {
        let spy = SpyAgentIntegrationProbeService()
        let home = FileManager.default.temporaryDirectory
        let model = makeModel(probeServices: { _ in spy }, homeDirectoryURL: home)
        let setup = AgentIntegrationSetup(enabled: true)

        let placeholder = model.state(for: .openCode, setup: setup)
        #expect(!placeholder.isAuthoritative)
        #expect(!placeholder.canInstall)
        // The placeholder must not borrow settled-state copy: it has not looked
        // yet, so it says so instead of claiming "Not installed".
        #expect(placeholder.status == .checking)
        #expect(placeholder.status.label == "Checking…")
        #expect(placeholder.status.detail == "Looking for an installed integration.")

        var authoritativeProbe = SpyAgentIntegrationProbeService.emptyProbe
        authoritativeProbe.templateExists = true
        spy.setResult(authoritativeProbe, for: .openCode)
        model.refresh(provider: .openCode, setup: setup)
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await settle()

        let authoritative = model.state(for: .openCode, setup: setup)
        #expect(authoritative.isAuthoritative)
        #expect(authoritative.canInstall)
        #expect(authoritative.status.label != placeholder.status.label)

        // A custom config home must not reach the filesystem from body
        // evaluation either: until a probe lands, the destination row shows the
        // unconditional default-home placeholder path.
        let customConfigHome = home.appending(path: "never-stat-me-\(UUID().uuidString)")
        let customSetup = AgentIntegrationSetup(enabled: true, configHome: customConfigHome.path)
        let customPlaceholder = model.state(for: .pi, setup: customSetup)
        #expect(customPlaceholder.isAuthoritative == false)
        #expect(customPlaceholder.globalInstallPath.hasSuffix(".pi/agent/extensions/awesomux-pi-status.ts"))
        #expect(customPlaceholder.globalInstallPath.contains(home.path))
        #expect(!customPlaceholder.globalInstallPath.contains("never-stat-me"))
    }

    @Test("a keystroke burst collapses into exactly one validation probe")
    func keystrokeBurstCollapsesIntoOneProbe() async throws {
        let spy = SpyAgentIntegrationProbeService()
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())

        for index in 0..<10 {
            model.scheduleDraftValidation(
                provider: .openCode,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/opt/homebrew/bin/oc-\(index)")
            )
        }

        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await settle()

        #expect(spy.callCounts[.openCode] == 1)
    }

    @Test("an older superseded probe cannot overwrite a newer publication")
    func staleGenerationCannotOverwriteNewerResult() async throws {
        let spy = SpyAgentIntegrationProbeService()
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())

        // Distinct outcomes per call: the held (older) probe validates the old
        // path; the newer debounced validation validates the new one.
        var olderProbe = SpyAgentIntegrationProbeService.emptyProbe
        olderProbe.binaryValidation = .unset("/opt/homebrew/bin/opencode")
        var newerProbe = SpyAgentIntegrationProbeService.emptyProbe
        newerProbe.binaryValidation = .valid("/opt/homebrew/bin/opencode-new")
        spy.script([olderProbe, newerProbe], for: .openCode)

        // First probe (explicit refresh) is held inside the service.
        spy.holdCalls(true)
        model.refresh(provider: .openCode, setup: AgentIntegrationSetup(enabled: true))
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)

        // Newer debounced validation completes while the older one is parked.
        let newerSetup = AgentIntegrationSetup(enabled: true, binaryPath: "/opt/homebrew/bin/opencode-new")
        spy.holdCalls(false)
        model.scheduleDraftValidation(provider: .openCode, setup: newerSetup)
        await spy.waitForCallCount(provider: .openCode, atLeast: 2)
        await settle()

        // Release the old generation last; it must lose despite finishing last.
        spy.releaseHeldCalls()
        await settle()

        let state = model.state(for: .openCode, setup: newerSetup)
        #expect(state.binaryValidation == .valid("/opt/homebrew/bin/opencode-new"))

        // The inverse interleaving: a parked validation loses to a commit
        // refresh that lands first.
        let spy2 = SpyAgentIntegrationProbeService()
        var staleValidation = SpyAgentIntegrationProbeService.emptyProbe
        staleValidation.binaryValidation = .invalid("stale")
        var committedResult = SpyAgentIntegrationProbeService.emptyProbe
        committedResult.binaryValidation = .valid("/committed")
        spy2.script([staleValidation, committedResult], for: .pi)

        let model2 = makeModel(probeServices: { _ in spy2 }, clock: ImmediateDelayClock())
        spy2.holdCalls(true)
        model2.scheduleDraftValidation(
            provider: .pi,
            setup: AgentIntegrationSetup(enabled: true, binaryPath: "/pending")
        )
        await spy2.waitForCallCount(provider: .pi, atLeast: 1)

        let committedSetup = AgentIntegrationSetup(enabled: true, binaryPath: "/committed")
        spy2.holdCalls(false)
        model2.refresh(provider: .pi, setup: committedSetup)
        await spy2.waitForCallCount(provider: .pi, atLeast: 2)
        await settle()
        spy2.releaseHeldCalls()
        await settle()

        let finalState = model2.state(for: .pi, setup: committedSetup)
        #expect(finalState.binaryValidation == .valid("/committed"))
    }

    @Test("status, validations, and action affordances publish coherently")
    func publicationIsCoherent() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var blocked = SpyAgentIntegrationProbeService.emptyProbe
        blocked.templateExists = false
        spy.setResult(blocked, for: .pi)
        let model = makeModel(probeServices: { _ in spy })

        model.refresh(provider: .pi, setup: AgentIntegrationSetup(enabled: true))
        await spy.waitForCallCount(provider: .pi, atLeast: 1)
        await settle()

        let state = model.state(for: .pi, setup: AgentIntegrationSetup(enabled: true))
        // Missing template blocks status; canInstall must agree with it.
        #expect(state.status == .blocked("Bundled template is missing"))
        #expect(!state.canInstall)
        #expect(state.isAuthoritative)
    }

    @Test("a transient busy observation retries once, then stands down")
    func transientBusyRetriesOnce() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var busy = SpyAgentIntegrationProbeService.emptyProbe
        busy.manifest = .busy
        spy.setResult(busy, for: .openCode)
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())

        model.refresh(provider: .openCode, setup: AgentIntegrationSetup(enabled: true))
        // The zero-delay retry cascades on its own: still busy after the single
        // retry, so it stands down instead of looping.
        await spy.waitForCallCount(provider: .openCode, atLeast: 2)
        await settle()
        #expect(spy.callCounts[.openCode] == 2)

        // A fresh explicit trigger clears the latch: probe three fires, sees
        // busy again, schedules one more retry (call four), then stands down.
        // Forced, like the pane's lifecycle triggers: an unchanged setup with a
        // settled card is otherwise absorbed as already observed.
        model.refresh(provider: .openCode, setup: AgentIntegrationSetup(enabled: true), forcing: true)
        await spy.waitForCallCount(provider: .openCode, atLeast: 4)
        await settle()
        #expect(spy.callCounts[.openCode] == 4)
    }

    @Test("cancelPendingWork drains scheduled validations without probing")
    func cancelPendingWorkDrainsWithoutProbing() async throws {
        let spy = SpyAgentIntegrationProbeService()
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())

        model.scheduleDraftValidation(provider: .pi, setup: AgentIntegrationSetup(enabled: true))
        // Cancels the debounce task before it can run; with the immediate clock
        // a surviving task would have probed during the settle below.
        model.cancelPendingWork()
        await settle()
        await settle()

        #expect((spy.callCounts[.pi] ?? 0) == 0)
    }

    @Test("each provider probes through its own probe service")
    func eachProviderProbesThroughItsOwnService() async throws {
        let openCodeSpy = SpyAgentIntegrationProbeService()
        let piSpy = SpyAgentIntegrationProbeService()
        let spies: [AgentIntegrationInstallProvider: SpyAgentIntegrationProbeService] = [
            .openCode: openCodeSpy,
            .pi: piSpy,
        ]
        let model = makeModel(probeServices: { spies[$0]! })

        // A stuck check on one provider must not block the other's: openCode's
        // probe is held, and pi's must still run and publish through its own
        // service instance.
        openCodeSpy.holdCalls(true)
        model.refresh(provider: .openCode, setup: AgentIntegrationSetup(enabled: true))
        await openCodeSpy.waitForCallCount(provider: .openCode, atLeast: 1)

        model.refresh(provider: .pi, setup: AgentIntegrationSetup(enabled: true))
        await piSpy.waitForCallCount(provider: .pi, atLeast: 1)
        await settle()

        #expect(piSpy.callCounts[.pi] == 1)
        #expect(model.state(for: .pi, setup: AgentIntegrationSetup(enabled: true)).isAuthoritative)
        openCodeSpy.releaseHeldCalls()
    }

    @Test("a stuck probe times out into a distinct couldn't-check state")
    func stuckProbeTimesOutIntoDistinctState() async throws {
        let spy = SpyAgentIntegrationProbeService()
        spy.holdCalls(true)
        let model = makeModel(probeServices: { _ in spy })
        let setup = AgentIntegrationSetup(enabled: true)

        model.refresh(provider: .openCode, setup: setup)
        // The immediate clock fires the watchdog as soon as it runs; give the
        // probe task and watchdog a real moment to execute.
        try await ContinuousClock().sleep(for: .milliseconds(50))

        let state = model.state(for: .openCode, setup: setup)
        #expect(state.status == .timedOut)
        #expect(state.status.label == "Couldn't check")
        #expect(state.isAuthoritative)
        #expect(!state.canInstall)
        #expect(!state.canUninstall)

        spy.releaseHeldCalls()
        await settle()
    }

    @Test("generation guard rejects a stale publication independent of cancellation")
    func generationGuardRejectsStalePublicationIndependentOfCancellation() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var current = SpyAgentIntegrationProbeService.emptyProbe
        current.binaryValidation = .valid("/current")
        spy.setResult(current, for: .openCode)
        let model = makeModel(probeServices: { _ in spy })
        let setup = AgentIntegrationSetup(enabled: true)

        model.refresh(provider: .openCode, setup: setup)
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await settle()
        #expect(model.state(for: .openCode, setup: setup).binaryValidation == .valid("/current"))

        // Drive a publication carrying generation 0 — older than anything this
        // model has issued — directly through the apply seam. The provider slot
        // is occupied by the live, uncancelled probe above, so only the
        // generation guard can stop this stale write.
        var stale = SpyAgentIntegrationProbeService.emptyProbe
        stale.binaryValidation = .invalid("/stale")
        model.apply(stale, provider: .openCode, setup: setup, generation: 0)
        await settle()

        let state = model.state(for: .openCode, setup: setup)
        #expect(state.binaryValidation == .valid("/current"))
        #expect(state.isAuthoritative)
    }

    @Test("one commit collapses targeted refresh and store echo into single probes")
    func singleCommitCollapsesIntoSingleProbes() async throws {
        let spy = SpyAgentIntegrationProbeService()
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())
        let openCodeSetup = AgentIntegrationSetup(enabled: true)
        let piSetup = AgentIntegrationSetup(enabled: false)

        // Pane appear.
        model.refreshAll(setupsByProvider: [.openCode: openCodeSetup, .pi: piSetup], forcing: true)
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await spy.waitForCallCount(provider: .pi, atLeast: 1)
        await settle()
        #expect(spy.callCounts[.openCode] == 1)
        #expect(spy.callCounts[.pi] == 1)

        // One commit: the pane's targeted refresh plus the self-triggered
        // store-write echo into refreshAll for every provider. Both must be
        // absorbed into zero additional probes.
        model.refresh(provider: .openCode, setup: openCodeSetup)
        model.refreshAll(setupsByProvider: [.openCode: openCodeSetup, .pi: piSetup])
        await settle()

        #expect(spy.callCounts[.openCode] == 1)
        #expect(spy.callCounts[.pi] == 1)
    }

    @Test("one install issues exactly one follow-up probe")
    func singleInstallIssuesExactlyOneFollowUpProbe() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var installed = SpyAgentIntegrationProbeService.emptyProbe
        installed.manifest = .loaded(installedPath: "/tmp/installed")
        installed.installedExists = true
        spy.setResult(installed, for: .openCode)
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())
        let openCodeSetup = AgentIntegrationSetup(enabled: true)
        let piSetup = AgentIntegrationSetup(enabled: false)

        model.refreshAll(setupsByProvider: [.openCode: openCodeSetup, .pi: piSetup], forcing: true)
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await spy.waitForCallCount(provider: .pi, atLeast: 1)
        await settle()

        // One install action: withdraw authority for the mutated files, run the
        // confirming probe, then absorb the store echo.
        model.invalidateObservation(provider: .openCode)
        model.refresh(provider: .openCode, setup: openCodeSetup)
        model.refreshAll(setupsByProvider: [.openCode: openCodeSetup, .pi: piSetup])
        await settle()

        #expect(spy.callCounts[.openCode] == 2)
        #expect(spy.callCounts[.pi] == 1)
    }

    @Test("invalidating observation withdraws action authority immediately")
    func invalidatedObservationWithdrawsAuthorityBeforeNextProbe() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var installed = SpyAgentIntegrationProbeService.emptyProbe
        installed.manifest = .loaded(installedPath: "/tmp/installed")
        installed.installedExists = true
        spy.setResult(installed, for: .openCode)
        let model = makeModel(probeServices: { _ in spy })
        let setup = AgentIntegrationSetup(enabled: true)

        model.refresh(provider: .openCode, setup: setup)
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await settle()
        #expect(model.state(for: .openCode, setup: setup).isAuthoritative)

        model.invalidateObservation(provider: .openCode)

        let invalidated = model.state(for: .openCode, setup: setup)
        #expect(!invalidated.isAuthoritative)
        #expect(!invalidated.canInstall)
        // The cached observation survives; only its authority is withdrawn.
        #expect(invalidated.isInstalledGlobally)
    }

    @Test("an unavailable manifest gives terminal guidance instead of retrying")
    func unavailableManifestDoesNotRetryAndExplainsCause() async throws {
        let spy = SpyAgentIntegrationProbeService()
        var unavailable = SpyAgentIntegrationProbeService.emptyProbe
        unavailable.manifest = .unavailable
        spy.setResult(unavailable, for: .openCode)
        let model = makeModel(probeServices: { _ in spy }, clock: ImmediateDelayClock())

        model.refresh(provider: .openCode, setup: AgentIntegrationSetup(enabled: true))
        await spy.waitForCallCount(provider: .openCode, atLeast: 1)
        await settle()
        await settle()

        // Not transient: exactly one probe, no bounded retry cascade.
        #expect(spy.callCounts[.openCode] == 1)
        let state = model.state(for: .openCode, setup: AgentIntegrationSetup(enabled: true))
        #expect(state.status.detail == "Can't read install state. Check permissions and available disk space.")
    }

    // MARK: - Helpers

    /// A small, BOUNDED number of yields: enough for the model's probe task to
    /// finish applying after the spy's call-count continuation fired, without
    /// the unbounded spin loops that starve the cooperative pool.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func makeModel(
        probeServices: @escaping @Sendable (AgentIntegrationInstallProvider) -> any AgentIntegrationProbing,
        clock: any AgentIntegrationSettingsSleeping = ImmediateDelayClock(),
        homeDirectoryURL: URL = FileManager.default.temporaryDirectory,
        probeTimeout: Duration = AgentIntegrationSettingsCardModel.defaultProbeTimeout
    ) -> AgentIntegrationSettingsCardModel {
        AgentIntegrationSettingsCardModel(
            viewModel: AgentIntegrationSettingsViewModel(homeDirectoryURL: homeDirectoryURL),
            probeServices: probeServices,
            clock: clock,
            validationDebounce: .milliseconds(50),
            transientRetryDelay: .milliseconds(100),
            probeTimeout: probeTimeout
        )
    }
}
