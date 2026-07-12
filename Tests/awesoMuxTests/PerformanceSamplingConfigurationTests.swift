import Foundation
import Testing
@testable import awesoMux

@Suite("PerformanceSamplingConfiguration")
struct PerformanceSamplingConfigurationTests {
    private let environmentKey = PerformanceSamplingConfiguration.environmentKey
    private let defaultsKey = PerformanceSamplingConfiguration.defaultsKey
    private let portSamplingEnvironmentKey = PerformanceSamplingConfiguration.portSamplingEnvironmentKey
    private let portSamplingDefaultsKey = PerformanceSamplingConfiguration.portSamplingDefaultsKey

    @Test("valid env value overrides saved defaults")
    func validEnvOverridesDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(30.0, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [environmentKey: "5"],
            userDefaults: defaults
        )
        #expect(interval == .milliseconds(5000))
    }

    @Test(
        "rejected env values fall through to saved defaults",
        arguments: ["0", "-5", "nan", "inf", "abc", ".nan", ".infinity"]
    )
    func rejectedEnvFallsThroughToDefaults(rawValue: String) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(30.0, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [environmentKey: rawValue],
            userDefaults: defaults
        )
        #expect(interval == .milliseconds(30_000))
    }

    @Test(
        "rejected env values without saved defaults disable sampling",
        arguments: ["0", "-5", "nan", "inf", "abc", ".nan", ".infinity"]
    )
    func rejectedEnvWithoutDefaultsDisablesSampling(rawValue: String) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [environmentKey: rawValue],
            userDefaults: defaults
        )
        #expect(interval == nil)
    }

    @Test("defaults below the minimum clamp up to 1s")
    func defaultsClampToMinimum() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.5, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [:],
            userDefaults: defaults
        )
        #expect(interval == .milliseconds(1000))
    }

    @Test("defaults above the maximum clamp down to 3600s")
    func defaultsClampToMaximum() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(99_999.0, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [:],
            userDefaults: defaults
        )
        #expect(interval == .milliseconds(3_600_000))
    }

    @Test("non-positive defaults fail the > 0 guard")
    func defaultsNonPositive() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(-1.0, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [:],
            userDefaults: defaults
        )
        #expect(interval == nil)
    }

    @Test("unparseable env value falls through to defaults")
    func unparseableEnvFallsThroughToDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(30.0, forKey: defaultsKey)

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [environmentKey: "abc"],
            userDefaults: defaults
        )
        #expect(interval == .milliseconds(30_000))
    }

    @Test("absent env and absent defaults yield nil")
    func absentEnvAndDefaultsYieldNil() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: [:],
            userDefaults: defaults
        )
        #expect(interval == nil)
    }

    @Test("port sampling is off by default")
    func portSamplingDefaultsOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [:],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == false)
    }

    @Test("port sampling env value 1 enables sampling")
    func portSamplingEnvOneEnables() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [portSamplingEnvironmentKey: "1"],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == true)
    }

    @Test("port sampling defaults true enables sampling when env is absent")
    func portSamplingDefaultsTrueEnables() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: portSamplingDefaultsKey)

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [:],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == true)
    }

    @Test("port sampling env 0 disables defaults true")
    func portSamplingEnvZeroOverridesDefaultsTrue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: portSamplingDefaultsKey)

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [portSamplingEnvironmentKey: "0"],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == false)
    }

    @Test("port sampling env 1 enables defaults false")
    func portSamplingEnvOneOverridesDefaultsFalse() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: portSamplingDefaultsKey)

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [portSamplingEnvironmentKey: "1"],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == true)
    }

    @Test("port sampling env values other than 1 do not fall through to defaults")
    func portSamplingInvalidEnvDisablesDefaultsTrue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: portSamplingDefaultsKey)

        let shouldSamplePorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: [portSamplingEnvironmentKey: "true"],
            userDefaults: defaults
        )
        #expect(shouldSamplePorts == false)
    }
}

@Suite("ProcessResourceSnapshot")
struct ProcessResourceSnapshotTests {
    @Test("mach port sampling defaults to the disabled sentinel")
    func machPortSamplingDefaultsDisabled() {
        var didSamplePorts = false

        let snapshot = ProcessResourceSnapshot.capture(
            surfaceCount: 2,
            machPortCountProvider: {
                didSamplePorts = true
                return 99
            }
        )

        #expect(didSamplePorts == false)
        #expect(snapshot.machPortCount == nil)
        #expect(snapshot.machPortLogValue == "disabled")
    }

    @Test("mach port sampling opt-in uses the sampled count")
    func machPortSamplingOptInUsesCount() {
        var didSamplePorts = false

        let snapshot = ProcessResourceSnapshot.capture(
            surfaceCount: 2,
            sampleMachPorts: true,
            machPortCountProvider: {
                didSamplePorts = true
                return 99
            }
        )

        #expect(didSamplePorts == true)
        #expect(snapshot.machPortCount == 99)
        #expect(snapshot.machPortLogValue == "99")
    }
}

@MainActor
@Suite("PerformanceSampler")
struct PerformanceSamplerTests {
    private let environmentKey = PerformanceSamplingConfiguration.environmentKey

    // A 1-hour interval makes the loop run its body exactly once (firing onSample) and
    // then park in a cancellable sleep — deterministic for both the start and deinit
    // tests, with no repeated-fire races.
    private let longInterval = "3600"

    @Test("starts a sampling task when an interval is requested")
    func startsWhenRequested() async {
        let sampler = PerformanceSampler()
        await confirmation("onSample fires once") { sampled in
            await withCheckedContinuation { continuation in
                sampler.startIfRequested(
                    environment: [environmentKey: longInterval],
                    onSample: {
                        sampled()
                        continuation.resume()
                    },
                    surfaceCount: { 0 }
                )
            }
        }
        sampler.stop()
    }

    @Test("a second startIfRequested is a genuine no-op, not a replacement")
    func doubleStartIsNoOp() async {
        let sampler = PerformanceSampler()
        await withCheckedContinuation { continuation in
            sampler.startIfRequested(
                environment: [environmentKey: longInterval],
                onSample: { continuation.resume() },
                surfaceCount: { 0 }
            )
        }
        #expect(sampler.taskCreationCount == 1)

        // Second call must short-circuit on the task != nil guard. Asserting the count
        // is unchanged (not merely that task is non-nil) proves no replacement task was
        // created.
        sampler.startIfRequested(
            environment: [environmentKey: longInterval],
            surfaceCount: { 0 }
        )
        #expect(sampler.taskCreationCount == 1)
        sampler.stop()
    }

    @Test("deinit cancels the live sampling task")
    func deinitCancelsTask() async {
        let stopStream = AsyncStream.makeStream(of: Void.self)
        let sampleStream = AsyncStream.makeStream(of: Void.self)

        // onStop runs from the task's defer block, which fires on any exit including the
        // cancellation triggered by deinit. With no self-capture in the task body,
        // dropping the last reference deallocates the sampler and its deinit cancels the
        // parked sleep — making the task exit and run the defer.
        await confirmation("onStop fires on teardown") { stopped in
            var sampler: PerformanceSampler? = PerformanceSampler()
            sampler?.startIfRequested(
                environment: [environmentKey: longInterval],
                onSample: { sampleStream.continuation.yield() },
                onStop: {
                    stopped()
                    stopStream.continuation.yield()
                },
                surfaceCount: { 0 }
            )

            // Wait until the task is confirmed live before dropping the reference, so we
            // are testing teardown of a running task and not a start/stop race.
            var sampleIterator = sampleStream.stream.makeAsyncIterator()
            await sampleIterator.next()

            sampler = nil

            var stopIterator = stopStream.stream.makeAsyncIterator()
            await stopIterator.next()
        }
    }
}

private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "PerformanceSamplingConfigurationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
