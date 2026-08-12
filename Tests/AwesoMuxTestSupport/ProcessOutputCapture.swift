import Foundation

/// Thrown when ``captureOutput(of:deadline:)``'s bounded wait expires.
///
/// Wraps the underlying ``ProcessWaitTimeout`` only to carry the capture
/// directory's path. The whole point of capturing a child's output is making
/// its failures diagnosable, so a timeout — the failure most likely to need
/// diagnosing — must not be the one case that discards the evidence.
public struct ProcessOutputCaptureTimeout: Error, CustomStringConvertible {
    public let underlying: any Error
    /// Deliberately left on disk. Whatever the child managed to flush before
    /// the deadline is usually the only clue to why it never exited.
    public let captureDirectory: URL

    public init(underlying: any Error, captureDirectory: URL) {
        self.underlying = underlying
        self.captureDirectory = captureDirectory
    }

    public var description: String {
        "\(underlying) Partial output preserved at \(captureDirectory.path)."
    }
}

/// Runs an already-configured `Process` to completion under a deadline and
/// returns everything it wrote.
///
/// Takes a configured process rather than an executable and arguments because
/// call sites variously set `environment` and `currentDirectoryURL`; a
/// signature covering every knob would just be `Process` again. The caller owns
/// configuration and reads `terminationStatus` afterwards — this owns only the
/// capture, which is the part that was wrong.
///
/// The pattern being replaced was `Pipe` → `waitUntilExitEventually()` →
/// `readDataToEndOfFile()`. That order deadlocks: a `Pipe` holds ~64KB, past
/// which the child blocks in `write()` while the parent is still inside the
/// wait that only the child's exit can end. Files have no buffer ceiling, so
/// the child never blocks and there is nothing to drain.
///
/// Three behaviours differ from the pipe version and are not defects to fix here:
///
/// 1. **Output can be truncated.** `readDataToEndOfFile()` returns at EOF,
///    which arrives only once *every* writer closes the write end — including a
///    grandchild that inherited it. `Data(contentsOf:)` returns whatever was
///    flushed when the child exited. A test whose child leaves a grandchild
///    running now reads short output instead of hanging until the deadline, so
///    an assertion about missing output can pass where it used to time out.
///    Assert on the presence of expected text, never on its absence.
/// 2. **A grandchild keeps the descriptors.** `waitUntilExitEventually`
///    deliberately never signals the child (see `ProcessBoundedWait.swift`), so
///    on the success path a surviving grandchild still holds the capture files
///    open after the directory is unlinked, writing to an inode with no name
///    until it exits. On the timeout path the directory is preserved, so those
///    writes stay reachable.
///    ponytail: bounded in practice — these fixtures stub `sleep` and exit in
///    milliseconds. Add an output cap or an explicit reap if a fixture ever
///    outlives its parent for real.
/// 3. **Invalid UTF-8 decodes to U+FFFD instead of vanishing.** Eleven of the
///    thirteen adopting call sites used `String(data:encoding:.utf8) ?? ""`, which threw
///    the entire stream away the moment one byte was malformed — a failure that
///    reads as "the command printed nothing". Replacement characters keep the
///    surrounding output readable, so this is the deliberate direction, not an
///    oversight.
/// Ceiling: on timeout this throws and preserves the capture files, but does
/// **not** reap the child — `ProcessBoundedWait` deliberately never signals a
/// possibly-recycled PID, so ownership stays with the caller exactly as it did
/// under the previous `Pipe` shape. A runner that can hang its child should
/// `defer` its own `terminate()`. Revisit if an orphan ever poisons a later test.
public func captureOutput(
    of process: Process,
    deadline: Duration = .seconds(30)
) throws -> (stdout: String, stderr: String) {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appending(path: "awesomux-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
    // 0700 at creation, not afterwards: macOS hands out a per-user `/var/folders`
    // temp root that is already private, but this helper is portable and Linux
    // `$TMPDIR` defaults to a world-readable `/tmp`, where a co-tenant on a
    // shared build host could read every captured child's output — indefinitely
    // on the timeout path, which deliberately preserves the files.
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    var preserveDirectory = false
    defer {
        if !preserveDirectory {
            try? fileManager.removeItem(at: directory)
        }
    }

    let stdoutURL = directory.appending(path: "stdout")
    let stderrURL = directory.appending(path: "stderr")
    try Data().write(to: stdoutURL)
    try Data().write(to: stderrURL)
    // Each handle gets its own `defer` the instant it exists. Registering one
    // `defer` after both opens would leak the first descriptor if the second
    // open throws, and the directory `defer` above would already have unlinked
    // the file — leaving an open handle on a nameless inode for the lifetime of
    // the test process, which hosts every suite.
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    defer { try? stdoutHandle.close() }
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer { try? stderrHandle.close() }

    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()
    do {
        try process.waitUntilExitEventually(deadline: deadline)
    } catch {
        preserveDirectory = true
        throw ProcessOutputCaptureTimeout(underlying: error, captureDirectory: directory)
    }

    return (
        stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
    )
}
