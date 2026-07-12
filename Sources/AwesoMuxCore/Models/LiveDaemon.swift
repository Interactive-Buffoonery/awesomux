import Foundation

/// A live `amx` (zmx) session daemon as reported by `amx list`. `createdEpoch`
/// is the daemon's own creation timestamp, used to fence GC to daemons that
/// existed before this launch's sweep began.
public struct LiveDaemon: Hashable, Sendable {
    public let id: TerminalSessionID
    public let pid: Int32
    public let createdEpoch: Int
    /// Attached client count from `amx list`. A daemon with `clients > 0` is
    /// in active use (this app's own pane, another terminal, or another
    /// awesoMux instance) and is never launch-GC'd.
    public let clients: Int

    public init(id: TerminalSessionID, pid: Int32, createdEpoch: Int, clients: Int) {
        self.id = id
        self.pid = pid
        self.createdEpoch = createdEpoch
        self.clients = clients
    }
}

/// One row of a `ps` process snapshot. `command` is the executable basename
/// (`ps comm=`), enough to recognize a login shell without parsing argv.
public struct ProcEntry: Hashable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let command: String

    public init(pid: Int32, ppid: Int32, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
    }
}
