import AwesoMuxBridgeProtocol

public struct ProcessSnapshot: Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let processSessionID: Int32
    public let controllingTerminal: Int64
    public let foregroundProcessGroupID: Int32
    public let state: Character
    public let command: String
    public let startTime: UInt64
    public let hasSessionMarker: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        processGroupID: Int32,
        processSessionID: Int32,
        controllingTerminal: Int64,
        foregroundProcessGroupID: Int32,
        state: Character = "S",
        command: String,
        startTime: UInt64 = 1,
        hasSessionMarker: Bool
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.processSessionID = processSessionID
        self.controllingTerminal = controllingTerminal
        self.foregroundProcessGroupID = foregroundProcessGroupID
        self.state = state
        self.command = command
        self.startTime = startTime
        self.hasSessionMarker = hasSessionMarker
    }

    func withMarker(_ hasSessionMarker: Bool) -> Self {
        Self(
            pid: pid,
            parentPID: parentPID,
            processGroupID: processGroupID,
            processSessionID: processSessionID,
            controllingTerminal: controllingTerminal,
            foregroundProcessGroupID: foregroundProcessGroupID,
            state: state,
            command: command,
            startTime: startTime,
            hasSessionMarker: hasSessionMarker
        )
    }
}

public struct ProcessTableSnapshot: Sendable {
    public let processes: [ProcessSnapshot]
    public let markerSeenButUnreadable: Bool

    public init(processes: [ProcessSnapshot], markerSeenButUnreadable: Bool = false) {
        self.processes = processes
        self.markerSeenButUnreadable = markerSeenButUnreadable
    }
}

public enum RemoteProcessLivenessClassifier {
    // Keep this set aligned with AwesoMuxCore's ShellRecognition. The Linux
    // helper cannot import the app-core target, but remote and local panes must
    // agree on which foreground processes can prove an idle shell.
    private static let recognizedShells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "csh", "tcsh", "nu",
        "pwsh", "xonsh", "elvish",
    ]

    public static func classify(_ snapshot: ProcessTableSnapshot) -> RemoteForegroundLivenessReport {
        let live = snapshot.processes.filter { $0.state != "Z" }
        let byPID = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0) })
        let marked = live.filter(\.hasSessionMarker)
        guard !marked.isEmpty else {
            return snapshot.markerSeenButUnreadable
                ? .init(state: .indeterminate)
                : .init(state: .gone)
        }
        guard !snapshot.markerSeenButUnreadable else {
            return .init(state: .indeterminate)
        }

        let outerCandidates = marked.filter { process in
            isRecognizedShell(process.command)
                && !hasMarkedShellAncestor(of: process, byPID: byPID)
        }
        guard outerCandidates.count == 1, let shell = outerCandidates.first else {
            return .init(state: .indeterminate)
        }
        guard shell.controllingTerminal > 0,
            shell.foregroundProcessGroupID > 0
        else {
            return .init(state: .indeterminate, comm: shell.command)
        }

        let paneProcesses = live.filter {
            $0.processSessionID == shell.processSessionID
                && $0.controllingTerminal == shell.controllingTerminal
                && isDescendantOrSelf($0, of: shell, byPID: byPID)
        }
        let foreground = paneProcesses.filter {
            $0.processGroupID == shell.foregroundProcessGroupID
        }
        guard !foreground.isEmpty else {
            return .init(state: .indeterminate, comm: shell.command)
        }

        if foreground.contains(where: { !isRecognizedShell($0.command) }) {
            let command = foreground.first(where: { !isRecognizedShell($0.command) })?.command
            return .init(state: .liveCommand, comm: command, hasChildren: nil)
        }

        guard foreground.contains(where: { $0.pid == shell.pid }) else {
            return .init(state: .indeterminate, comm: foreground.first?.command)
        }
        let descendants = paneProcesses.filter { $0.pid != shell.pid }
        if !descendants.isEmpty {
            return .init(state: .busyShell, comm: shell.command, hasChildren: true)
        }
        return .init(state: .idleShell, comm: shell.command, hasChildren: false)
    }

    private static func hasMarkedShellAncestor(
        of process: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> Bool {
        var parentPID = process.parentPID
        var visited: Set<Int32> = []
        while parentPID > 0, visited.insert(parentPID).inserted, let parent = byPID[parentPID] {
            if parent.hasSessionMarker, isRecognizedShell(parent.command) { return true }
            parentPID = parent.parentPID
        }
        return false
    }

    private static func isDescendantOrSelf(
        _ process: ProcessSnapshot,
        of root: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> Bool {
        if process.pid == root.pid { return true }
        var parentPID = process.parentPID
        var visited: Set<Int32> = []
        while parentPID > 0, visited.insert(parentPID).inserted, let parent = byPID[parentPID] {
            if parent.pid == root.pid { return true }
            parentPID = parent.parentPID
        }
        return false
    }

    private static func isRecognizedShell(_ command: String) -> Bool {
        let basename = command.split(separator: "/").last.map(String.init) ?? command
        let normalized = basename.hasPrefix("-") ? String(basename.dropFirst()) : basename
        return recognizedShells.contains(normalized)
    }
}
