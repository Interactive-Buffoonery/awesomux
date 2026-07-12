import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Diagnostics processes")
struct DiagnosticsProcessTests {
    @Test("parses metrics without treating executable paths as arguments")
    func parsesMetricsAndExecutablePaths() throws {
        let rows = DiagnosticsProcessParser.parse(
            """
              42   1  12.5  2048 /Applications/awesoMux Preview.app/Contents/MacOS/awesoMux
              43  42   0.4   512 /bin/zsh
            """
        )

        #expect(rows.count == 2)
        let app = try #require(rows.first)
        #expect(app.pid == 42)
        #expect(app.parentPID == 1)
        #expect(app.cpuPercent == 12.5)
        #expect(app.residentBytes == 2_097_152)
        #expect(app.executablePath == "/Applications/awesoMux Preview.app/Contents/MacOS/awesoMux")
    }

    @Test("groups daemon descendants and deduplicates aggregate processes")
    func groupsDaemonDescendants() throws {
        let sessionID = try #require(TerminalSessionID(rawValue: "11111111-1111-1111-1111-111111111111"))
        let rows = DiagnosticsProcessParser.parse(
            """
            100 1 4.0 1000 /Applications/awesoMux.app/Contents/MacOS/awesoMux
            110 100 0.2 100 /usr/local/bin/amx
            111 100 9.0 500 /bin/ps
            200 1 1.0 200 /usr/local/bin/amx
            201 200 3.0 300 /bin/zsh
            202 201 8.0 400 /usr/local/bin/codex
            """
        )
        let snapshot = DiagnosticsProcessTree.build(
            rows: rows,
            daemons: [LiveDaemon(id: sessionID, pid: 200, createdEpoch: 0, clients: 1)],
            owners: [sessionID: .init(sessionTitle: "Feature", paneTitle: "Agent", isSelected: true)],
            appPID: 100,
            collectedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].processes.map(\.pid) == [200, 201, 202])
        #expect(snapshot.groups[0].isSelected)
        #expect(snapshot.aggregateProcessCount == 5)
        #expect(snapshot.childProcessCount == 4)
        #expect(snapshot.aggregateCPUPercent == 16.2)
    }

    @Test("excludes the short-lived process sampler from diagnostics")
    func excludesProcessSampler() {
        let rows = DiagnosticsProcessParser.parse(
            """
            100 1 4.0 1000 /Applications/awesoMux.app/Contents/MacOS/awesoMux
            110 100 25.0 500 /bin/ps
            """
        )

        let snapshot = DiagnosticsProcessTree.build(
            rows: rows,
            daemons: [],
            owners: [:],
            appPID: 100,
            collectedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.appProcesses.map(\.pid) == [100])
        #expect(snapshot.aggregateProcessCount == 1)
        #expect(snapshot.aggregateCPUPercent == 4)
    }

    @Test("ignores a stale daemon PID that now belongs to another executable")
    func ignoresRecycledDaemonPID() throws {
        let sessionID = try #require(TerminalSessionID(rawValue: "11111111-1111-1111-1111-111111111111"))
        let rows = DiagnosticsProcessParser.parse(
            """
            100 1 4.0 1000 /Applications/awesoMux.app/Contents/MacOS/awesoMux
            200 1 1.0 200 /usr/bin/unrelated-service
            201 200 3.0 300 /bin/zsh
            """
        )

        let snapshot = DiagnosticsProcessTree.build(
            rows: rows,
            daemons: [LiveDaemon(id: sessionID, pid: 200, createdEpoch: 0, clients: 1)],
            owners: [:],
            appPID: 100,
            collectedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.appProcesses.map(\.pid) == [100])
        #expect(snapshot.aggregateProcessCount == 1)
    }
}
