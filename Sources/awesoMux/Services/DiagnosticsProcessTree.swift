import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

enum DiagnosticsProcessTree {
    static func build(
        rows: [DiagnosticsRawProcess],
        daemons: [LiveDaemon],
        owners: [TerminalSessionID: DiagnosticsSessionOwner],
        appPID: Int32,
        collectedAt: Date,
        daemonListAvailable: Bool = true
    ) -> DiagnosticsProcessSnapshot {
        let capturedRows = rows.filter { row in
            !(row.parentPID == appPID && row.executablePath == "/bin/ps")
        }
        let byPID = Dictionary(capturedRows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: capturedRows, by: \.parentPID)
        let daemonPIDs = Set(daemons.map(\.pid))

        var assigned = Set<Int32>()
        let groups = daemons.compactMap { daemon -> DiagnosticsProcessGroup? in
            guard let root = byPID[daemon.pid], isDaemonExecutable(root.executablePath) else {
                return nil
            }
            let pids = descendants(of: daemon.pid, children: children)
            let processes = pids.compactMap { pid in
                byPID[pid].map { process(from: $0, appPID: appPID, daemonPIDs: daemonPIDs) }
            }.sorted { $0.pid < $1.pid }
            guard !processes.isEmpty else { return nil }
            assigned.formUnion(pids)
            let owner = owners[daemon.id]
            return DiagnosticsProcessGroup(
                sessionID: daemon.id,
                title: owner?.displayName ?? "amx:\(daemon.id.rawValue.prefix(8))",
                isSelected: owner?.isSelected ?? false,
                processes: processes
            )
        }

        let appProcesses = descendants(of: appPID, children: children)
            .subtracting(assigned)
            .compactMap { pid in
                byPID[pid].map { process(from: $0, appPID: appPID, daemonPIDs: daemonPIDs) }
            }
            .sorted { $0.pid < $1.pid }

        return DiagnosticsProcessSnapshot(
            collectedAt: collectedAt,
            appPID: appPID,
            daemonListAvailable: daemonListAvailable,
            appProcesses: appProcesses,
            groups: groups.sorted {
                if $0.isSelected != $1.isSelected { return $0.isSelected }
                return $0.cpuPercent > $1.cpuPercent
            }
        )
    }

    private static func isDaemonExecutable(_ executablePath: String) -> Bool {
        let basename = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return basename == "amx" || basename == "zmx"
    }

    private static func descendants(
        of root: Int32,
        children: [Int32: [DiagnosticsRawProcess]]
    ) -> Set<Int32> {
        var result = Set<Int32>()
        var pending = [root]
        while let pid = pending.popLast() {
            guard result.insert(pid).inserted else { continue }
            pending.append(contentsOf: children[pid, default: []].map(\.pid))
        }
        return result
    }

    private static func process(
        from row: DiagnosticsRawProcess,
        appPID: Int32,
        daemonPIDs: Set<Int32>
    ) -> DiagnosticsProcess {
        let basename = row.name.lowercased()
        let kind: DiagnosticsProcessKind
        if row.pid == appPID {
            kind = .app
        } else if daemonPIDs.contains(row.pid) {
            kind = .daemon
        } else if ShellRecognition.isRecognizedShell(row.executablePath) {
            kind = .shell
        } else if AgentProcessRecognition.agentKind(forCommand: row.executablePath) != nil
                    || basename == "claude" || basename.hasPrefix("claude-") {
            kind = .agent
        } else if basename == "amx" || basename == "zmx" {
            kind = .bridge
        } else {
            kind = .other
        }
        return DiagnosticsProcess(
            pid: row.pid,
            parentPID: row.parentPID,
            cpuPercent: row.cpuPercent,
            residentBytes: row.residentBytes,
            executablePath: row.executablePath,
            kind: kind
        )
    }
}
