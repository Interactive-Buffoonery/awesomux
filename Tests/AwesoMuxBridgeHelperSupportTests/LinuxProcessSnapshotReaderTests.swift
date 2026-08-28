#if os(Linux)
    import Foundation
    import Testing
    @testable import AwesoMuxBridgeHelperSupport

    @Suite
    struct LinuxProcessSnapshotReaderTests {
        @Test func parsesStatWithSpacesAndClosingParenthesisInCommand() throws {
            let fixture = try ProcFixture()
            defer { fixture.remove() }
            try fixture.add(
                pid: 42,
                stat: "42 (my ) shell) S 1 42 42 34817 42 0 0 0 0 0 0 0 0 0 0 0 0 0 777",
                environment: "AWESOMUX_BRIDGE_SESSION=session-1\0"
            )

            let snapshot = LinuxProcessSnapshotReader(procPath: fixture.path)
                .read(sessionID: "session-1")
            let process = try #require(snapshot.processes.first)
            #expect(process.command == "my ) shell")
            #expect(process.parentPID == 1)
            #expect(process.processGroupID == 42)
            #expect(process.processSessionID == 42)
            #expect(process.controllingTerminal == 34817)
            #expect(process.foregroundProcessGroupID == 42)
            #expect(process.startTime == 777)
            #expect(process.hasSessionMarker)
        }

        @Test func environmentRequiresAnExactNullDelimitedEntry() throws {
            let fixture = try ProcFixture()
            defer { fixture.remove() }
            let stat = "42 (zsh) S 1 42 42 34817 42 0 0 0 0 0 0 0 0 0 0 0 0 0 777"
            try fixture.add(
                pid: 42,
                stat: stat,
                environment: "XAWESOMUX_BRIDGE_SESSION=session-1\0AWESOMUX_BRIDGE_SESSION=session-10\0"
            )

            let snapshot = LinuxProcessSnapshotReader(procPath: fixture.path)
                .read(sessionID: "session-1")
            #expect(snapshot.processes.first?.hasSessionMarker == false)
        }
    }

    private struct ProcFixture {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("awesomux-proc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func add(pid: Int, stat: String, environment: String) throws {
            let processURL = url.appendingPathComponent(String(pid), isDirectory: true)
            try FileManager.default.createDirectory(at: processURL, withIntermediateDirectories: true)
            try Data(stat.utf8).write(to: processURL.appendingPathComponent("stat"))
            try Data(environment.utf8).write(to: processURL.appendingPathComponent("environ"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }
#endif
