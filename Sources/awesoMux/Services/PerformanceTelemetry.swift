import Foundation
import os

@MainActor
final class PerformanceSampler {
    private let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "Performance"
    )
    private var task: Task<Void, Never>?

    // Observable across the @testable boundary (private would not be): lets a test
    // prove a second startIfRequested was a genuine no-op, not a task replacement.
    private(set) var taskCreationCount = 0

    func startIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        onSample: (@Sendable () -> Void)? = nil,
        onStop: (@Sendable () -> Void)? = nil,
        surfaceCount: @escaping @Sendable @MainActor () -> Int
    ) {
        guard task == nil else {
            return
        }
        guard let interval = PerformanceSamplingConfiguration.requestedInterval(
            environment: environment,
            userDefaults: userDefaults
        ) else {
            return
        }
        let sampleMachPorts = PerformanceSamplingConfiguration.shouldSamplePorts(
            environment: environment,
            userDefaults: userDefaults
        )

        taskCreationCount += 1
        // Capture hooks and logger by value, never self: a detached task that retains
        // self would keep the sampler alive past its last reference and prevent deinit
        // from ever firing (the deinit-cancellation test depends on this).
        task = Task.detached { [logger, onSample, onStop, sampleMachPorts] in
            defer { onStop?() }
            while !Task.isCancelled {
                let count = await MainActor.run { surfaceCount() }
                let snapshot = ProcessResourceSnapshot.capture(
                    surfaceCount: count,
                    sampleMachPorts: sampleMachPorts
                )
                // privacy: .public is safe here — every field is a process-self scalar
                // metric (counts, byte totals from task_info). Do NOT copy this marker to
                // sibling Logger calls that interpolate user-controlled strings.
                logger.info(
                    """
                    perf-sample surfaces=\(snapshot.surfaceCount, privacy: .public) \
                    resident_bytes=\(snapshot.residentBytes, privacy: .public) \
                    phys_footprint_bytes=\(snapshot.physFootprintBytes, privacy: .public) \
                    threads=\(snapshot.threadCount, privacy: .public) \
                    mach_ports=\(snapshot.machPortLogValue, privacy: .public)
                    """
                )
                onSample?()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

enum PerformanceSamplingConfiguration {
    static let environmentKey = "AWESOMUX_PERF_SAMPLE_INTERVAL_SECONDS"
    static let defaultsKey = "perfSampleIntervalSeconds"
    static let portSamplingEnvironmentKey = "AWESOMUX_PERF_SAMPLE_PORTS"
    static let portSamplingDefaultsKey = "perfSamplePorts"
    private static let minimumIntervalSeconds = 1.0
    private static let maximumIntervalSeconds = 3_600.0

    static func requestedInterval(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Duration? {
        if let rawValue = environment[environmentKey],
           let seconds = Double(rawValue),
           let interval = interval(seconds: seconds) {
            return interval
        }

        guard userDefaults.object(forKey: defaultsKey) != nil else {
            return nil
        }
        return interval(seconds: userDefaults.double(forKey: defaultsKey))
    }

    static func shouldSamplePorts(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if let rawValue = environment[portSamplingEnvironmentKey] {
            return rawValue == "1"
        }

        guard userDefaults.object(forKey: portSamplingDefaultsKey) != nil else {
            return false
        }
        return userDefaults.bool(forKey: portSamplingDefaultsKey)
    }

    private static func interval(seconds: Double) -> Duration? {
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }

        let clampedSeconds = min(
            max(seconds, minimumIntervalSeconds),
            maximumIntervalSeconds
        )
        let milliseconds = Int64((clampedSeconds * 1_000).rounded())
        return .milliseconds(milliseconds)
    }
}

struct ProcessResourceSnapshot {
    let surfaceCount: Int
    let residentBytes: Int64
    let physFootprintBytes: Int64
    let threadCount: Int64
    let machPortCount: Int64?

    var machPortLogValue: String {
        guard let machPortCount else {
            return "disabled"
        }
        return "\(machPortCount)"
    }

    static func capture(
        surfaceCount: Int,
        sampleMachPorts: Bool = false,
        machPortCountProvider: () -> Int64 = processMachPortCount
    ) -> ProcessResourceSnapshot {
        let memory = ProcessMemorySnapshot.capture()
        return ProcessResourceSnapshot(
            surfaceCount: surfaceCount,
            residentBytes: memory.map { Int64($0.residentBytes) } ?? -1,
            physFootprintBytes: memory.map { Int64($0.physFootprintBytes) } ?? -1,
            threadCount: processThreadCount(),
            machPortCount: sampleMachPorts ? machPortCountProvider() : nil
        )
    }

    private static func processThreadCount() -> Int64 {
        var threadList: thread_act_array_t?
        var count = mach_msg_type_number_t()
        let result = task_threads(mach_task_self_, &threadList, &count)
        guard result == KERN_SUCCESS, let threadList else {
            return -1
        }

        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threadList[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        return Int64(count)
    }

    private static func processMachPortCount() -> Int64 {
        var names: mach_port_name_array_t?
        var namesCount = mach_msg_type_number_t()
        var types: mach_port_type_array_t?
        var typesCount = mach_msg_type_number_t()

        let result = mach_port_names(
            mach_task_self_,
            &names,
            &namesCount,
            &types,
            &typesCount
        )
        guard result == KERN_SUCCESS else {
            return -1
        }

        defer {
            if let names {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: names)),
                    vm_size_t(Int(namesCount) * MemoryLayout<mach_port_name_t>.stride)
                )
            }
            if let types {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(UInt(bitPattern: types)),
                    vm_size_t(Int(typesCount) * MemoryLayout<mach_port_type_t>.stride)
                )
            }
        }

        return Int64(namesCount)
    }
}
