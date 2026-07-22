import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Remote clipboard handoff", .serialized)
struct RemoteHandoffTests {
    @Test("clipboard priority and remote classification follow the decision table")
    func clipboardClassification() throws {
        let directory = try TemporaryDirectory(prefix: "handoff-classifier")
        let markdown = directory.url.appendingPathComponent("notes.md")
        let secondMarkdown = directory.url.appendingPathComponent("other.markdown")
        let imageFile = directory.url.appendingPathComponent("image.png")
        let unsupported = directory.url.appendingPathComponent("notes.txt")
        let markdownDirectory = directory.url.appendingPathComponent("archive.md")
        for url in [markdown, secondMarkdown, imageFile, unsupported] {
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: markdownDirectory, withIntermediateDirectories: false)

        let oneMarkdown = pasteboard(urls: [markdown], text: "incidental text")
        let oneContent = try #require(TerminalPasteboardString.content(from: oneMarkdown))
        guard case .markdown(let url) = TerminalPasteboardString.remoteHandoffCandidate(from: oneContent) else {
            Issue.record("one Markdown file should hand off")
            return
        }
        #expect(url == markdown)

        for urls in [[markdown, secondMarkdown], [unsupported], [imageFile], [markdownDirectory]] {
            let pasteboard = pasteboard(urls: urls)
            let content = try #require(TerminalPasteboardString.content(from: pasteboard))
            #expect(TerminalPasteboardString.remoteHandoffCandidate(from: content) == nil)
            #expect(
                TerminalPasteboardString.string(from: content)
                    == urls
                    .map { TerminalInsertionEscaping.escape($0.path) }
                    .joined(separator: " "))
        }

        let textAndImage = NSPasteboard(name: .init("handoff-rich-\(UUID())"))
        textAndImage.clearContents()
        textAndImage.setString("https://example.com", forType: .string)
        textAndImage.setData(Data([1, 2, 3]), forType: .png)
        let richContent = try #require(TerminalPasteboardString.content(from: textAndImage))
        #expect(TerminalPasteboardString.string(from: richContent) == "https://example.com")
        #expect(TerminalPasteboardString.remoteHandoffCandidate(from: richContent) == nil)

        #expect(TerminalPasteboardString.remoteHandoffCandidate(from: .text("hello")) == nil)
        #expect(
            TerminalPasteboardString.remoteHandoffCandidate(
                from: .urls([URL(string: "https://example.com")!])
            ) == nil)
        guard case .png = TerminalPasteboardString.remoteHandoffCandidate(from: .png(Data([1]))) else {
            Issue.record("image-only PNG should hand off")
            return
        }
        guard case .tiff = TerminalPasteboardString.remoteHandoffCandidate(from: .tiff(Data([1]))) else {
            Issue.record("image-only TIFF should hand off")
            return
        }
    }

    @Test("local image-only paste still materializes and inserts a temporary PNG path")
    func localImagePasteIsUnchanged() throws {
        let escaped = try #require(TerminalPasteboardString.string(from: .png(Data([1, 2, 3]))))
        let path = escaped.replacingOccurrences(of: "\\ ", with: " ")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Markdown source validation rejects unsafe types and enforces the 10 MB boundary")
    func sourceValidation() async throws {
        let directory = try TemporaryDirectory(prefix: "handoff-source")
        let exact = directory.url.appendingPathComponent("exact.md")
        FileManager.default.createFile(atPath: exact.path, contents: nil)
        let exactHandle = try FileHandle(forWritingTo: exact)
        try exactHandle.truncate(atOffset: UInt64(RemoteHandoff.maximumByteCount))
        try exactHandle.close()
        let exactSource = try await RemoteHandoff.prepare(.markdown(exact))
        #expect(exactSource.byteCount == RemoteHandoff.maximumByteCount)

        let over = directory.url.appendingPathComponent("over.md")
        FileManager.default.createFile(atPath: over.path, contents: nil)
        let overHandle = try FileHandle(forWritingTo: over)
        try overHandle.truncate(atOffset: UInt64(RemoteHandoff.maximumByteCount + 1))
        try overHandle.close()

        let folder = directory.url.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fifo = directory.url.appendingPathComponent("pipe.md")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let symlink = directory.url.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: exact)
        let unsupported = directory.url.appendingPathComponent("notes.txt")
        try Data().write(to: unsupported)

        for url in [
            directory.url.appendingPathComponent("missing.md"), folder, fifo, symlink, unsupported, over,
        ] {
            await #expect(throws: RemoteHandoff.Failure.sourceUnavailable) {
                try await RemoteHandoff.prepare(.markdown(url))
            }
        }
        await #expect(throws: RemoteHandoff.Failure.sourceUnavailable) {
            try await RemoteHandoff.prepare(.png(Data(count: RemoteHandoff.maximumByteCount + 1)))
        }
        await #expect(throws: RemoteHandoff.Failure.sourceUnavailable) {
            try await RemoteHandoff.prepare(.tiff(Data(count: RemoteHandoff.maximumByteCount + 1)))
        }
    }

    @Test("source replacement after confirmation is rejected by descriptor identity")
    func changedSourceIsRejected() async throws {
        let directory = try TemporaryDirectory(prefix: "handoff-source")
        let url = directory.url.appendingPathComponent("notes.md")
        try Data("old".utf8).write(to: url)
        let source = try await RemoteHandoff.prepare(.markdown(url))
        try FileManager.default.removeItem(at: url)
        try Data("new".utf8).write(to: url)
        #expect(throws: RemoteHandoff.Failure.sourceUnavailable) {
            try source.openValidated()
        }
    }

    @Test("window-less confirmation aborts without presenting an app-modal alert")
    func windowlessConfirmationAborts() async throws {
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let confirmed = await RemoteHandoff.confirmationProvider(
            remote,
            "notes.md",
            "~/.awesomux/handoffs/session-1/",
            nil
        )
        #expect(!confirmed)
    }

    @Test("receipt validation rejects malformed, unsafe, and wrong-directory paths")
    func receiptValidation() throws {
        let sessionID = try #require(TerminalSessionID(rawValue: "session-1"))
        let expected = "/home/me/.awesomux/handoffs/session-1/file.md"
        #expect(receipt(path: expected, bytes: 3, sessionID: sessionID) == expected)
        #expect(receipt(path: "/home/me/.awesomux/handoffs/session-1/a/../file.md", bytes: 3, sessionID: sessionID) == expected)

        let rejected = [
            "relative.md",
            "/home/me/.awesomux/handoffs/session-1",
            "/home/me/.awesomux/handoffs/session-10/file.md",
            "/home/me/.awesomux/handoffs/other/file.md",
            "/home/me/.awesomux/handoffs/session-1/evil\u{202e}.md",
            "/home/me/.awesomux/handoffs/session-1/evil\n.md",
        ]
        for path in rejected {
            #expect(receipt(path: path, bytes: 3, sessionID: sessionID) == nil)
        }
        #expect(receipt(path: expected, bytes: 4, sessionID: sessionID) == nil)
        #expect(
            RemoteHandoff.validatedReceiptPath(
                Data(#"{"path":"/home/me/.awesomux/handoffs/session-1/file.md","bytes":3} {}"#.utf8),
                remoteHome: "/home/me", sessionID: sessionID, expectedBytes: 3
            ) == nil)
        #expect(
            RemoteHandoff.validatedReceiptPath(
                Data(repeating: 0x20, count: RemoteHandoff.maximumReceiptByteCount + 1),
                remoteHome: "/home/me", sessionID: sessionID, expectedBytes: 3
            ) == nil)
    }

    @Test("captured authority ignores selection but rejects identity changes")
    func authorityValidation() throws {
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let terminalID = try #require(TerminalSessionID(rawValue: "session-1"))
        var pane = TerminalPane(
            terminalSessionID: terminalID,
            title: "remote", workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: remote))
        )
        let authority = RemoteHandoff.Authority(
            appSessionID: UUID(), paneID: pane.id, terminalSessionID: terminalID,
            executionPlan: pane.executionPlan, remote: remote
        )
        #expect(RemoteHandoff.authorityMatches(authority, pane: pane))
        #expect(!RemoteHandoff.authorityMatches(authority, pane: nil))

        pane.executionPlan = .local
        #expect(!RemoteHandoff.authorityMatches(authority, pane: pane))
        pane.executionPlan = authority.executionPlan
        pane.terminalSessionID = .generate()
        #expect(!RemoteHandoff.authorityMatches(authority, pane: pane))
    }

    @Test("capability and SSH arguments are exact and privacy-safe")
    func capabilityAndArguments() throws {
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let arguments = RemoteHandoff.sshArguments(
            remote: remote,
            controlPath: "/tmp/control/%C",
            remoteCommand: "'/home/me/.awesomux/bin/awesomux-bridge-helper' receive-handoff"
        )
        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPath=/tmp/control/%C"))
        #expect(arguments.contains("ConnectTimeout=10"))
        #expect(arguments.contains("me@example"))
        #expect(!arguments.joined(separator: " ").contains("/Users/local/private-notes.md"))
    }

    @Test("transfer streams source bytes on stdin without exposing the source path")
    func transferStreamsSourceBytes() async throws {
        let directory = try TemporaryDirectory(prefix: "handoff-transfer")
        let sourceURL = directory.url.appendingPathComponent("private-notes.md")
        let capturedInput = directory.url.appendingPathComponent("captured-input")
        let capturedArguments = directory.url.appendingPathComponent("captured-arguments")
        let payload = Data("secret contents".utf8)
        try payload.write(to: sourceURL)
        let source = try await RemoteHandoff.prepare(.markdown(sourceURL))
        let executable = try shellScript(
            in: directory,
            body: """
                cat > \(shellQuote(capturedInput.path))
                printf '%s\\n' "$@" > \(shellQuote(capturedArguments.path))
                printf '%s' '{"path":"/home/me/.awesomux/handoffs/session-1/notes.md","bytes":15}'
                """
        )
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let sessionID = try #require(TerminalSessionID(rawValue: "session-1"))

        let receipt = try await RemoteHandoff.transfer(
            source: source,
            remote: remote,
            controlPath: "/tmp/control/%C",
            helperPath: "/home/me/.awesomux/bin/awesomux-bridge-helper",
            sessionID: sessionID,
            executableURL: executable,
            timeout: .seconds(2)
        )

        #expect(try Data(contentsOf: capturedInput) == payload)
        #expect(!(try String(contentsOf: capturedArguments, encoding: .utf8)).contains(sourceURL.path))
        #expect(
            RemoteHandoff.validatedReceiptPath(
                receipt,
                remoteHome: "/home/me",
                sessionID: sessionID,
                expectedBytes: payload.count
            ) != nil)
    }

    @Test(
        "transfer rejects nonzero exit and oversized stdout",
        arguments: [
            "cat >/dev/null; exit 7",
            "cat >/dev/null; head -c 5000 /dev/zero",
        ])
    func transferRejectsProcessFailures(body: String) async throws {
        let harness = try await transferHarness(scriptBody: body)
        await #expect(throws: RemoteHandoff.Failure.transferFailed) {
            try await RemoteHandoff.transfer(
                source: harness.source,
                remote: harness.remote,
                controlPath: "/tmp/control/%C",
                helperPath: "/remote/helper",
                sessionID: harness.sessionID,
                executableURL: harness.executable,
                timeout: .seconds(2)
            )
        }
    }

    @Test("transfer enforces its whole-operation timeout")
    func transferTimesOut() async throws {
        let harness = try await transferHarness(scriptBody: "exec sleep 5")
        await #expect(throws: RemoteHandoff.Failure.transferFailed) {
            try await RemoteHandoff.transfer(
                source: harness.source,
                remote: harness.remote,
                controlPath: "/tmp/control/%C",
                helperPath: "/remote/helper",
                sessionID: harness.sessionID,
                executableURL: harness.executable,
                timeout: .milliseconds(50)
            )
        }
    }

    @Test("transfer terminates on task cancellation")
    func transferCancellation() async throws {
        let harness = try await transferHarness(scriptBody: "exec sleep 5")
        let transfer = Task {
            try await RemoteHandoff.transfer(
                source: harness.source,
                remote: harness.remote,
                controlPath: "/tmp/control/%C",
                helperPath: "/remote/helper",
                sessionID: harness.sessionID,
                executableURL: harness.executable,
                timeout: .seconds(2)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        transfer.cancel()
        await #expect(throws: CancellationError.self) {
            try await transfer.value
        }
    }

    private func pasteboard(urls: [URL], text: String? = nil) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("handoff-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        if let text { pasteboard.setString(text, forType: .string) }
        return pasteboard
    }

    private func receipt(
        path: String,
        bytes: Int,
        sessionID: TerminalSessionID
    ) -> String? {
        let data = try? JSONSerialization.data(withJSONObject: ["path": path, "bytes": bytes])
        return data.flatMap {
            RemoteHandoff.validatedReceiptPath(
                $0, remoteHome: "/home/me", sessionID: sessionID, expectedBytes: 3
            )
        }
    }

    private func transferHarness(scriptBody: String) async throws -> (
        directory: TemporaryDirectory,
        source: RemoteHandoff.PreparedSource,
        executable: URL,
        remote: RemoteTarget,
        sessionID: TerminalSessionID
    ) {
        let directory = try TemporaryDirectory(prefix: "handoff-transfer")
        let sourceURL = directory.url.appendingPathComponent("notes.md")
        try Data("abc".utf8).write(to: sourceURL)
        return (
            directory,
            try await RemoteHandoff.prepare(.markdown(sourceURL)),
            try shellScript(in: directory, body: scriptBody),
            try #require(RemoteTarget(parsing: "me@example")),
            try #require(TerminalSessionID(rawValue: "session-1"))
        )
    }

    @Test("transfer uses an immutable snapshot when the source inode changes in place")
    func transferSnapshotsSourceBytes() async throws {
        let directory = try TemporaryDirectory(prefix: "handoff-transfer-snapshot")
        let sourceURL = directory.url.appendingPathComponent("private-notes.md")
        let capturedInput = directory.url.appendingPathComponent("captured-input")
        let startedMarker = directory.url.appendingPathComponent("started")
        let original = Data(repeating: 0x41, count: 256 * 1024)
        let replacement = Data(repeating: 0x42, count: original.count)
        try original.write(to: sourceURL)
        let source = try await RemoteHandoff.prepare(.markdown(sourceURL))
        let executable = try shellScript(
            in: directory,
            body: """
                touch \(shellQuote(startedMarker.path))
                sleep 0.2
                cat > \(shellQuote(capturedInput.path))
                printf '%s' '{"path":"/home/me/.awesomux/handoffs/session-1/notes.md","bytes":\(original.count)}'
                """
        )
        let remote = try #require(RemoteTarget(parsing: "me@example"))
        let sessionID = try #require(TerminalSessionID(rawValue: "session-1"))

        let transfer = Task {
            try await RemoteHandoff.transfer(
                source: source,
                remote: remote,
                controlPath: "/tmp/control/%C",
                helperPath: "/home/me/.awesomux/bin/awesomux-bridge-helper",
                sessionID: sessionID,
                executableURL: executable,
                timeout: .seconds(2)
            )
        }
        defer { transfer.cancel() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: startedMarker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: startedMarker.path))

        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.synchronize()
        try handle.close()

        _ = try await transfer.value
        #expect(try Data(contentsOf: capturedInput) == original)
    }

    private func shellScript(in directory: TemporaryDirectory, body: String) throws -> URL {
        let url = directory.url.appendingPathComponent("fake-ssh.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
