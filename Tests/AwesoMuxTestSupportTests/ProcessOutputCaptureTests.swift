import Foundation
import Testing

@testable import AwesoMuxTestSupport

@Suite("Process output capture")
struct ProcessOutputCaptureTests {
    /// 256KB, comfortably past the ~64KB a `Pipe` will hold. Below the buffer
    /// the broken and the fixed shapes are indistinguishable, so a smaller
    /// payload would make this test vacuously green.
    private static let payloadBytes = 256 * 1024

    private static func flooder() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "head -c \(payloadBytes) /dev/zero | tr '\\0' 'x'; printf 'x' >&2",
        ]
        return process
    }

    /// This test does not itself run the pattern being replaced, so read the
    /// claim as history rather than as something asserted here: the identical
    /// child driven through `Pipe` → wait → `readDataToEndOfFile()` was
    /// confirmed to hang and die on a 5s deadline before this helper existed,
    /// while this shape returns in ~15ms.
    @Test("output far past a pipe's buffer arrives whole")
    func capturesBeyondPipeBuffer() throws {
        let process = Self.flooder()
        let captured = try captureOutput(of: process, deadline: .seconds(30))
        #expect(process.terminationStatus == 0)
        #expect(captured.stdout.utf8.count == Self.payloadBytes)
        #expect(captured.stderr == "x")
    }

    @Test("a timeout preserves the partial capture and names where it went")
    func timeoutPreservesPartialOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `exec` so the sleeper IS the tracked process. Without it bash forks,
        // `terminate()` reaps only bash, and the orphaned `sleep` keeps the
        // capture files open for its full 30s.
        process.arguments = ["-c", "printf 'partial'; exec sleep 30"]

        var preserved: URL?
        defer {
            process.terminate()
            try? process.waitUntilExitEventually(deadline: .seconds(10))
            if let preserved {
                try? FileManager.default.removeItem(at: preserved)
            }
        }

        do {
            _ = try captureOutput(of: process, deadline: .seconds(2))
            Issue.record("a child that never exits must not report success")
        } catch let timeout as ProcessOutputCaptureTimeout {
            preserved = timeout.captureDirectory
            let stdout = timeout.captureDirectory.appending(path: "stdout")
            #expect(FileManager.default.fileExists(atPath: stdout.path))
            #expect(try String(contentsOf: stdout, encoding: .utf8) == "partial")
            #expect(timeout.description.contains(timeout.captureDirectory.path))
        }
    }
}
// Cleanup on the success path is deliberately not asserted here: the capture
// directories share one temp root, Swift Testing runs `@Test`s concurrently,
// and the helper does not surface its directory when it succeeds — so any
// count- or listing-based check races every other suite that captures output.
