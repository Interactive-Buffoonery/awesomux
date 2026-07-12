import AwesoMuxCore
import Foundation

struct DiagnosticsRawProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let residentBytes: Int64
    let executablePath: String

    var name: String {
        URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

enum DiagnosticsProcessKind: String, Sendable {
    case app = "App"
    case daemon = "Daemon"
    case shell = "Shell"
    case agent = "Agent"
    case bridge = "Bridge"
    case other = "Process"

    var displayName: String {
        switch self {
        case .app: String(localized: "App", comment: "Diagnostics process type")
        case .daemon: String(localized: "Daemon", comment: "Diagnostics process type")
        case .shell: String(localized: "Shell", comment: "Diagnostics process type")
        case .agent: String(localized: "Agent", comment: "Diagnostics process type")
        case .bridge: String(localized: "Bridge", comment: "Diagnostics process type")
        case .other: String(localized: "Process", comment: "Diagnostics process type")
        }
    }

    var systemImage: String {
        switch self {
        case .app: "macwindow"
        case .daemon: "server.rack"
        case .shell: "terminal"
        case .agent: "sparkles"
        case .bridge: "arrow.triangle.branch"
        case .other: "gearshape"
        }
    }
}

struct DiagnosticsProcess: Identifiable, Equatable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let residentBytes: Int64
    let executablePath: String
    let kind: DiagnosticsProcessKind

    var name: String {
        URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

struct DiagnosticsSessionOwner: Equatable, Sendable {
    let sessionTitle: String
    let paneTitle: String
    let isSelected: Bool

    var displayName: String { "\(sessionTitle) · \(paneTitle)" }
}

struct DiagnosticsProcessGroup: Identifiable, Equatable, Sendable {
    var id: TerminalSessionID { sessionID }
    let sessionID: TerminalSessionID
    let title: String
    let isSelected: Bool
    let processes: [DiagnosticsProcess]

    var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    var residentBytes: Int64 { processes.reduce(0) { $0 + $1.residentBytes } }
}

struct DiagnosticsProcessSnapshot: Equatable, Sendable {
    let collectedAt: Date
    let appPID: Int32
    let daemonListAvailable: Bool
    let appProcesses: [DiagnosticsProcess]
    let groups: [DiagnosticsProcessGroup]
    let aggregateProcessCount: Int
    let childProcessCount: Int
    let aggregateCPUPercent: Double
    let aggregateResidentBytes: Int64

    init(
        collectedAt: Date,
        appPID: Int32,
        daemonListAvailable: Bool,
        appProcesses: [DiagnosticsProcess],
        groups: [DiagnosticsProcessGroup]
    ) {
        self.collectedAt = collectedAt
        self.appPID = appPID
        self.daemonListAvailable = daemonListAvailable
        self.appProcesses = appProcesses
        self.groups = groups
        let grouped = groups.flatMap(\.processes)
        var seen = Set<Int32>()
        let allProcesses = (appProcesses + grouped).filter { seen.insert($0.pid).inserted }
        self.aggregateProcessCount = allProcesses.count
        self.childProcessCount = allProcesses.count { $0.pid != appPID }
        self.aggregateCPUPercent = allProcesses.reduce(0) { $0 + $1.cpuPercent }
        self.aggregateResidentBytes = allProcesses.reduce(0) { $0 + $1.residentBytes }
    }
}
