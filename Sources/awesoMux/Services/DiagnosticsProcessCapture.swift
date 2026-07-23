import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

enum DiagnosticsProcessCapture {
    /// Process snapshot + optional daemon discovery. Safe to call off the MainActor:
    /// pure value inputs, process I/O via `AmxBackend`, pure tree build.
    static func capture(
        owners: [TerminalSessionID: DiagnosticsSessionOwner],
        at date: Date,
        purpose: DiagnosticsCapturePurpose
    ) async -> DiagnosticsCaptureResult? {
        let needsDaemonList: Bool = switch purpose {
        case let .sample(_, rediscoverDaemons, _): rediscoverDaemons
        case .refresh: true
        }

        let processRows: [DiagnosticsRawProcess]
        let listResult: [LiveDaemon]?
        if needsDaemonList {
            // Independent subprocesses — run in parallel so refresh/rediscovery
            // pay the max of the two timeouts, not the sum.
            async let rowsTask = AmxBackend.currentDiagnosticsProcessSnapshot()
            async let listTask = AmxBackend.listSessionsResult()
            guard let rows = await rowsTask else { return nil }
            processRows = rows
            listResult = await listTask
        } else {
            guard let rows = await AmxBackend.currentDiagnosticsProcessSnapshot() else {
                return nil
            }
            processRows = rows
            listResult = nil
        }

        let daemons: [LiveDaemon]
        let discoveredDaemons: [LiveDaemon]?
        let daemonListAvailable: Bool
        switch purpose {
        case let .sample(knownDaemons, rediscoverDaemons, lastListAvailable):
            if rediscoverDaemons {
                if let listResult {
                    daemons = listResult
                    discoveredDaemons = listResult
                    daemonListAvailable = true
                } else {
                    daemons = knownDaemons
                    discoveredDaemons = nil
                    daemonListAvailable = false
                }
            } else {
                daemons = knownDaemons
                discoveredDaemons = nil
                daemonListAvailable = lastListAvailable
            }
        case let .refresh(fallbackDaemons):
            daemons = listResult ?? fallbackDaemons
            discoveredDaemons = listResult
            daemonListAvailable = listResult != nil
        }

        let snapshot = DiagnosticsProcessTree.build(
            rows: processRows,
            daemons: daemons,
            owners: owners,
            appPID: ProcessInfo.processInfo.processIdentifier,
            collectedAt: date,
            daemonListAvailable: daemonListAvailable
        )
        return DiagnosticsCaptureResult(
            snapshot: snapshot,
            discoveredDaemons: discoveredDaemons
        )
    }
}
