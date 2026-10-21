import AwesoMuxConfig
import Foundation

// Drives the production ProcessAgentPluginRunner against the real `claude`
// CLI with two disposable CLAUDE_CONFIG_DIR folders. Every step prints one JSON
// line: what the runner reports, what `claude plugin list --json` says for each
// folder when asked directly, and which folders awesoMux has install records for.
//
// `driver <work> <claude> <resources> <install|uninstall> <A|B|C>` runs one
// mutation instead and prints the outcome plus the raw manifest on disk, so
// run.py can interleave a build compiled from an older revision against the
// same install state.
//
// `driver <work> <claude> <resources> concurrency` exercises concurrent
// same-provider status probes: legacy import while a sibling holds the
// install-state lock, and the Settings pane's two-wide folder sweep.

@main
struct Driver {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard [4, 5, 6].contains(arguments.count) else {
            FileHandle.standardError.write(
                Data("usage: driver <work-dir> <claude> <resources-dir> [op folder | concurrency]\n".utf8))
            exit(2)
        }
        let work = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let claude = arguments[2]
        let resources = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let fileManager = FileManager.default

        let support = work.appending(path: "support", directoryHint: .isDirectory)
        let home = work.appending(path: "home", directoryHint: .isDirectory)
        let folderA = home.appending(path: ".claude-personal", directoryHint: .isDirectory)
        let folderB = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        let folderC = home.appending(path: ".claude-spare", directoryHint: .isDirectory)
        let helper = work.appending(path: "bin/awesoMuxAgentHook")
        for directory in [support, folderA, folderB, folderC, helper.deletingLastPathComponent()] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let stateDirectory = support.appending(path: "state", directoryHint: .isDirectory)
        let runner = ProcessAgentPluginRunner(
            renderer: AgentPluginTemplateRenderer(
                resourcesDirectoryURL: resources,
                supportDirectoryURL: support,
                bundleIdentifier: "com.interactivebuffoonery.awesomux.e2e"
            ),
            homeDirectoryURL: home,
            helperPathResolver: { AgentHookHelperPath(path: helper.path, isDevelopmentBundle: false) },
            ladderProbe: { _ in false },
            installStateDirectoryURL: stateDirectory
        )
        let allFolders = ["A": folderA, "B": folderB, "C": folderC]
        let folders = ["A": folderA, "B": folderB]
        func setup(_ name: String) -> AgentIntegrationSetup {
            AgentIntegrationSetup(enabled: true, binaryPath: claude, configHome: allFolders[name]!.path)
        }

        if arguments.count == 5, arguments[4] == "concurrency" {
            try await concurrency(
                work: work, claude: claude, resources: resources, helper: helper, seeder: runner,
                seedState: stateDirectory, folders: allFolders
            )
            return
        }

        if arguments.count == 6 {
            let op = arguments[4]
            let name = arguments[5]
            let outcome: AgentPluginActionOutcome
            switch op {
            case "install": outcome = await runner.enableOrInstall(provider: .claudeCode, setup: setup(name))
            case "uninstall": outcome = await runner.uninstall(provider: .claudeCode, setup: setup(name))
            default:
                FileHandle.standardError.write(Data("unknown op \(op)\n".utf8))
                exit(2)
            }
            var line: [String: Any] = [
                "op": op, "folder": name, "outcome": outcome.status.label, "outcomeDetail": outcome.status.detail,
            ]
            var cliTruth: [String: Bool] = [:]
            for (key, folder) in allFolders {
                cliTruth[key] = installedPerCLI(claude: claude, configHome: folder)
            }
            line["cliInstalled"] = cliTruth
            let manifestURL = stateDirectory.appending(path: "plugin-install-manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                line["manifestVersion"] = object["version"]
                line["recordedFolders"] = ((object["records"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["configHome"] as? String }
                    .map { path in
                        allFolders.first { URL(fileURLWithPath: path).standardizedFileURL == $0.value.standardizedFileURL }?.key
                            ?? path
                    }
                    .sorted()
            }
            let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        func record(_ step: String, outcome: AgentPluginActionOutcome? = nil) async {
            var line: [String: Any] = ["step": step]
            if let outcome {
                line["outcome"] = outcome.status.label
                line["outcomeDetail"] = outcome.status.detail
            }
            var runnerStatus: [String: String] = [:]
            var cliTruth: [String: Bool] = [:]
            for (name, folder) in folders.sorted(by: { $0.key < $1.key }) {
                runnerStatus[name] = await runner.status(provider: .claudeCode, setup: setup(name)).status.label
                cliTruth[name] = installedPerCLI(claude: claude, configHome: folder)
            }
            line["runnerStatus"] = runnerStatus
            line["cliInstalled"] = cliTruth
            let manifest = runner.loadInstallManifest()
            line["recordedFolders"] = manifest.records
                .filter { $0.provider == .claudeCode }
                .map { recorded in
                    folders.first { URL(fileURLWithPath: recorded.configHome).standardizedFileURL == $0.value.standardizedFileURL }?.key
                        ?? recorded.configHome
                }
                .sorted()
            let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }

        await record("initial")
        await record("install-A", outcome: await runner.enableOrInstall(provider: .claudeCode, setup: setup("A")))
        await record("install-B", outcome: await runner.enableOrInstall(provider: .claudeCode, setup: setup("B")))
        await record("remove-A", outcome: await runner.uninstall(provider: .claudeCode, setup: setup("A")))
        await record("remove-B", outcome: await runner.uninstall(provider: .claudeCode, setup: setup("B")))
    }

    static func emit(_ line: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    static func concurrency(
        work: URL, claude: String, resources: URL, helper: URL, seeder: ProcessAgentPluginRunner,
        seedState: URL, folders: [String: URL]
    ) async throws {
        let fileManager = FileManager.default
        func setup(_ name: String, binary: String = claude) -> AgentIntegrationSetup {
            AgentIntegrationSetup(enabled: true, binaryPath: binary, configHome: folders[name]!.path)
        }
        let seedA = await seeder.enableOrInstall(provider: .claudeCode, setup: setup("A"))
        let seedB = await seeder.enableOrInstall(provider: .claudeCode, setup: setup("B"))
        emit(["step": "seed", "outcome": [seedA.status.label, seedB.status.label]])

        // The seeded manifest becomes the only (legacy) copy; canonical state is empty.
        let manifestName = "plugin-install-manifest.json"
        let legacy = work.appending(path: "legacy", directoryHint: .isDirectory)
        let state = work.appending(path: "state-imported", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fileManager.copyItem(at: seedState.appending(path: manifestName), to: legacy.appending(path: manifestName))
        let legacyBytes = try Data(contentsOf: legacy.appending(path: manifestName))
        let runner = ProcessAgentPluginRunner(
            renderer: AgentPluginTemplateRenderer(
                resourcesDirectoryURL: resources,
                supportDirectoryURL: work.appending(path: "support", directoryHint: .isDirectory),
                bundleIdentifier: "com.interactivebuffoonery.awesomux.e2e"
            ),
            homeDirectoryURL: work.appending(path: "home", directoryHint: .isDirectory),
            helperPathResolver: { AgentHookHelperPath(path: helper.path, isDevelopmentBundle: false) },
            ladderProbe: { _ in false },
            installStateDirectoryURL: state,
            legacyInstallStateDirectoryURL: legacy
        )
        let canonical = state.appending(path: manifestName)
        let store = AgentInstallManifestStore<AgentPluginInstallManifest>(
            manifestURL: canonical, legacyManifestURL: legacy.appending(path: manifestName), fileManager: fileManager
        )

        func probeBurst(_ step: String) async {
            struct Probe: Sendable {
                var folder: String
                var status: String
                var busyNote: Bool
                var records: Int
            }
            let probes = await withTaskGroup(of: Probe.self) { group in
                for index in 0..<6 {
                    let name = index.isMultiple(of: 2) ? "A" : "B"
                    group.addTask {
                        let report = await runner.status(provider: .claudeCode, setup: setup(name))
                        return Probe(
                            folder: name, status: report.status.label,
                            busyNote: report.note?.contains("Another awesoMux instance") == true,
                            records: runner.loadInstallManifest().records.count
                        )
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            emit([
                "step": step,
                "statuses": Set(probes.map { "\($0.folder)=\($0.status)" }).sorted(),
                "anyBusyNote": probes.contains { $0.busyNote },
                "recordCounts": Set(probes.map(\.records)).sorted(),
                "canonicalExists": fileManager.fileExists(atPath: canonical.path),
            ])
        }

        // A sibling probe mid-import holds the lock; deterministic stand-in for losing the race.
        let held = try AgentIntegrationInstallStateLock.acquire(in: state)
        let control: String
        switch store.loadState() {
        case .failed(.busy): control = "busy"
        case .failed: control = "failed"
        case .missing: control = "missing"
        case .loaded: control = "loaded"
        }
        emit(["step": "lock-held-control", "storeLoadState": control])
        await probeBurst("lock-held-probes")
        let guarded = await runner.uninstall(provider: .claudeCode, setup: setup("A"))
        emit([
            "step": "lock-held-mutation", "outcome": guarded.status.label,
            "cliInstalledA": installedPerCLI(claude: claude, configHome: folders["A"]!),
            "canonicalExists": fileManager.fileExists(atPath: canonical.path),
        ])
        held.release()

        await probeBurst("released-probes")
        emit([
            "step": "imported",
            "canonicalEqualsLegacy": (try? Data(contentsOf: canonical)) == legacyBytes,
        ])

        // The pane's sweep, mirrored: at most two probes in flight, next folder
        // starts as soon as one finishes. Folder C goes first and its CLI is slow;
        // it must be unrecorded, since a recorded install pins its own binary.
        let slowClaude = work.appending(path: "bin/slow-claude")
        try Data(
            """
            #!/bin/sh
            case "$CLAUDE_CONFIG_DIR" in *claude-spare*) sleep 4 ;; esac
            exec '\(claude)' "$@"

            """.utf8
        ).write(to: slowClaude)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowClaude.path)
        let tracker = SweepTracker()
        var pending = ["C", "A", "B"][...]
        await withTaskGroup(of: Void.self) { group in
            func startNext() {
                guard !Task.isCancelled, let name = pending.popFirst() else { return }
                group.addTask {
                    await tracker.start()
                    let started = Date()
                    let report = await runner.status(provider: .claudeCode, setup: setup(name, binary: slowClaude.path))
                    await tracker.finish(name, status: report.status.label, seconds: Date().timeIntervalSince(started))
                }
            }
            startNext()
            startNext()
            while await group.next() != nil {
                startNext()
            }
        }
        emit([
            "step": "sweep",
            "completionOrder": await tracker.order,
            "maxInFlight": await tracker.maxInFlight,
            "statuses": await tracker.statuses,
            "seconds": await tracker.seconds,
            "slowestFolder": await tracker.seconds.max { $0.value < $1.value }?.key ?? "",
        ])

        _ = await runner.uninstall(provider: .claudeCode, setup: setup("A"))
        _ = await runner.uninstall(provider: .claudeCode, setup: setup("B"))
        emit([
            "step": "cleanup",
            "cliInstalled": [
                "A": installedPerCLI(claude: claude, configHome: folders["A"]!),
                "B": installedPerCLI(claude: claude, configHome: folders["B"]!),
            ],
        ])
    }

    /// Independent truth: ask the CLI directly, bypassing the runner.
    static func installedPerCLI(claude: String, configHome: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["plugin", "list", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configHome.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return entries.contains { entry in
            ((entry["id"] ?? entry["name"]) as? String)?.hasPrefix("awesomux-runtime-status") == true
        }
    }
}

actor SweepTracker {
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var order: [String] = []
    private(set) var statuses: [String: String] = [:]
    private(set) var seconds: [String: Double] = [:]

    func start() {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func finish(_ name: String, status: String, seconds elapsed: Double) {
        inFlight -= 1
        order.append(name)
        statuses[name] = status
        seconds[name] = (elapsed * 10).rounded() / 10
    }
}
