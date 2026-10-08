import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Remote browser real SSH E2E", .serialized)
struct RemoteBrowserE2ETests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["AWESOMUX_BROWSER_E2E"] == "1",
            "Set AWESOMUX_BROWSER_E2E=1 and the documented fixture paths to run the real SSH E2E."
        )
    )
    @MainActor
    func realHelperSSHBridgeAndPromptJourney() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sshConfig = try #require(environment["AWESOMUX_BROWSER_E2E_SSH_CONFIG"])
        let helper = try #require(environment["AWESOMUX_BROWSER_E2E_HELPER"])
        let artifactPath = try #require(environment["AWESOMUX_BROWSER_E2E_ARTIFACT_DIR"])
        let artifact = URL(fileURLWithPath: artifactPath, isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)

        let fixture = try BrowserSSHFixture(sshConfig: sshConfig, helper: helper, artifact: artifact)
        defer { fixture.stop() }

        let actor = try BridgeConnectionActor(
            expectedToken: fixture.token,
            expectedSession: fixture.session,
            socketName: "browser-e2e.sock"
        )
        fixture.localSocket = actor.socketPath
        try fixture.restartForward()

        let frames = EventRecorder<BridgeEnvelope>()
        let sink = BrowserE2ESink()
        let supervisor = BridgeConnectionSupervisor(
            connectionActor: actor,
            expectedToken: fixture.token,
            expectedSession: fixture.session,
            frameSink: { envelope, _ in await frames.record(envelope) },
            connectionLostSink: { _ in },
            browserRequestSink: { envelope, generation in
                await sink.receive(envelope, generation: generation)
            },
            browserConnectionLostSink: { generation in
                await sink.connectionLost(generation)
            }
        )

        let settings = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: artifact.appending(path: "config.toml")),
            legacySnapshotProvider: { nil }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 720, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "awesoMux remote browser E2E"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let coordinator = RemoteBrowserCoordinator(
            token: fixture.token,
            session: fixture.session,
            settings: settings,
            destination: { fixture.destination },
            window: { window },
            isConnected: { generation in await sink.isActive(generation) },
            reply: { envelope, generation in await sink.reply(envelope, generation: generation) }
        )
        sink.configure(supervisor: supervisor, coordinator: coordinator)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        var report: [String] = []
        defer {
            try? (report.joined(separator: "\n") + "\n").write(
                to: artifact.appending(path: "browser-e2e-report.txt"), atomically: true, encoding: .utf8
            )
        }
        func record(_ value: String) { report.append(value) }

        let invalid = try await fixture.runBrowser(url: "file:///tmp/not-web", timeout: 5)
        #expect(invalid.status == 1 && invalid.stderr.contains("browser open invalid"))
        record("PASS non-web scheme rejected")

        settings.workspaces.update { $0.remoteBrowserEnabled = false }
        let disabled = try await fixture.runBrowser(url: "https://example.invalid/disabled", timeout: 5)
        #expect(disabled.status == 1 && disabled.stderr.contains("browser open disabled"))
        settings.workspaces.update { $0.remoteBrowserEnabled = true }
        record("PASS disabled setting rejects a new request")

        let pending = fixture.runBrowserTask(url: "https://example.invalid/pending", timeout: 20)
        let sheet = try await requireSheet(on: window)
        try saveScreenshot(of: sheet, to: artifact.appending(path: "browser-prompt.png"))

        let busy = try await fixture.runBrowser(url: "https://example.invalid/busy", timeout: 5)
        #expect(busy.status == 1 && busy.stderr.contains("browser open busy"))
        record("PASS second browser lane receives busy while a prompt is pending")

        try fixture.writeStatusFixture()
        let status = try await fixture.runStatusFixture()
        #expect(status.status == 0)
        #expect(await frames.waitForCount(1, deadline: .seconds(5)))
        #expect(
            await frames.values.contains { envelope in
                if case .agentStatus(let value) = envelope.message { return value.eventID == "browser-e2e-status" }
                return false
            })
        record("PASS legacy status hook is delivered while browser prompt is pending")

        try clickButton("Cancel", in: sheet)
        let cancelled = try await pending.value
        #expect(cancelled.status == 1 && cancelled.stderr.contains("browser open cancelled"))
        try await requireSheetDismissal(sheet, on: window)
        record("PASS Cancel returns cancelled")

        let copyURL = "https://example.invalid/copy%20path?q=one%26two#fragment"
        let copy = fixture.runBrowserTask(url: copyURL, timeout: 20)
        let copySheet = try await requireSheet(on: window)
        try clickButton("Copy Link", in: copySheet)
        let copied = try await copy.value
        #expect(
            copied.status == 1
                && copied.stderr.contains("browser open copied")
                && copied.stderr.contains(copyURL)
        )
        #expect(NSPasteboard.general.string(forType: .string) == copyURL)
        try await requireSheetDismissal(copySheet, on: window)
        record("PASS Copy Link copies the exact URL and returns copied")

        try await Task.sleep(for: .seconds(10.2))
        let receiver = try BrowserHitReceiver(artifact: artifact)
        defer { receiver.stop() }
        let openURL = "http://127.0.0.1:\(try await receiver.port())/opened?source=ssh"
        let open = fixture.runBrowserTask(url: openURL, timeout: 30)
        let openSheet = try await requireSheet(on: window)
        try clickButton("Open Link", in: openSheet)
        let opened = try await open.value
        #expect(opened.status == 0)
        #expect(try await receiver.waitForHit(expected: "/opened?source=ssh"))
        try await requireSheetDismissal(openSheet, on: window)
        let openOrigin = "http://127.0.0.1:\(receiver.resolvedPort)"
        settings.workspaces.update {
            $0.remoteBrowserAllowedOrigins[fixture.destination] = [openOrigin]
        }
        #expect(
            settings.workspaces.value.remoteBrowserAllowedOrigins[fixture.destination]?.contains(
                openOrigin) == true)
        record("PASS Open Link reaches the local browser receiver")

        let remembered = try await fixture.runBrowser(url: openURL, timeout: 30)
        #expect(remembered.status == 0)
        record("PASS an origin saved through the real settings store opens without a second prompt")

        settings.workspaces.update { $0.remoteBrowserAllowedOrigins.removeAll() }
        let revoked = fixture.runBrowserTask(url: openURL, timeout: 20)
        let revokedSheet = try await requireSheet(on: window)
        try clickButton("Cancel", in: revokedSheet)
        let revokedResult = try await revoked.value
        #expect(revokedResult.stderr.contains("browser open cancelled"))
        try await requireSheetDismissal(revokedSheet, on: window)
        record("PASS revoking the remembered origin restores the prompt")

        try await Task.sleep(for: .seconds(10.2))
        let expiring = fixture.runBrowserTask(url: "https://example.invalid/expiry", timeout: 1)
        let expiringSheet = try await requireSheet(on: window)
        let expired = try await expiring.value
        #expect(expired.status == 1 && expired.stderr.contains("browser open expired"))
        try await requireSheetDismissal(expiringSheet, on: window)
        record("PASS request expiry closes the prompt and returns expired")

        let disconnecting = fixture.runBrowserTask(url: "https://example.invalid/disconnect", timeout: 20)
        let disconnectingSheet = try await requireSheet(on: window)
        fixture.stopForward()
        let disconnected = try await disconnecting.value
        #expect(disconnected.status == 1 && disconnected.stderr.contains("browser open disconnected"))
        try await requireSheetDismissal(disconnectingSheet, on: window)
        record("PASS tunnel loss closes the prompt and returns disconnected")

        try fixture.startForward()
        let reconnected = fixture.runBrowserTask(url: "https://example.invalid/reconnected", timeout: 20)
        let reconnectedSheet = try await requireSheet(on: window, excluding: disconnectingSheet)
        try clickButton("Cancel", in: reconnectedSheet)
        let reconnectedResult = try await reconnected.value
        try #require(reconnectedResult.stderr.contains("browser open cancelled"))
        record("PASS a fresh tunnel reconnect serves a new browser request")

    }

    @MainActor
    private func requireSheet(on window: NSWindow, excluding oldSheet: NSWindow? = nil) async throws -> NSWindow {
        let appeared = await waitUntilEventually(deadline: .seconds(8)) {
            guard let sheet = window.attachedSheet else { return false }
            return oldSheet.map { sheet !== $0 } ?? true
        }
        guard appeared, let sheet = window.attachedSheet,
            oldSheet.map({ sheet !== $0 }) ?? true
        else {
            Issue.record("browser prompt did not appear")
            throw BrowserE2EError.promptMissing
        }
        return sheet
    }

    @MainActor
    private func requireSheetDismissal(_ sheet: NSWindow, on window: NSWindow) async throws {
        let dismissed = await waitUntilEventually(deadline: .seconds(5)) {
            window.attachedSheet !== sheet
        }
        guard dismissed else {
            Issue.record("browser prompt did not finish dismissing")
            throw BrowserE2EError.promptDidNotDismiss
        }
    }

    @MainActor
    private func clickButton(_ title: String, in sheet: NSWindow) throws {
        let button = try #require(findButton(in: sheet.contentView, matching: { $0.title == title }))
        button.performClick(nil)
    }

    @MainActor
    private func findButton(in view: NSView?, matching predicate: (NSButton) -> Bool) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, predicate(button) { return button }
        for child in view.subviews {
            if let match = findButton(in: child, matching: predicate) { return match }
        }
        return nil
    }

    @MainActor
    private func saveScreenshot(of window: NSWindow, to url: URL) throws {
        guard let view = window.contentView,
            let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw BrowserE2EError.screenshotFailed }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw BrowserE2EError.screenshotFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

private enum BrowserE2EError: Error {
    case forwardFailed(String)
    case promptDidNotDismiss
    case promptMissing
    case receiverFailed
    case screenshotFailed
}

@MainActor
private final class BrowserE2ESink {
    private var supervisor: BridgeConnectionSupervisor?
    private var coordinator: RemoteBrowserCoordinator?

    func configure(supervisor: BridgeConnectionSupervisor, coordinator: RemoteBrowserCoordinator) {
        self.supervisor = supervisor
        self.coordinator = coordinator
    }

    func receive(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation) {
        coordinator?.receive(envelope, generation: generation)
    }

    func connectionLost(_ generation: BridgeConnectionActor.Generation) {
        coordinator?.connectionLost(generation)
    }

    func isActive(_ generation: BridgeConnectionActor.Generation) async -> Bool {
        await supervisor?.isBrowserGenerationActive(generation) ?? false
    }

    func reply(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation) async {
        _ = await supervisor?.sendBrowserResult(envelope: envelope, generation: generation)
    }
}

private final class BrowserSSHFixture: @unchecked Sendable {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    let sshConfig: String
    let helper: String
    let artifact: URL
    let destination = "awesomux-browser-e2e"
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let session = UUID().uuidString.lowercased()
    let remoteSocket: String
    let stateFile: URL
    let statusFixture: URL
    var localSocket = ""
    private var forward: Process?
    private var forwardOutput: FileHandle?
    private let resultLogLock = NSLock()

    init(sshConfig: String, helper: String, artifact: URL) throws {
        self.sshConfig = sshConfig
        self.helper = helper
        self.artifact = artifact
        let suffix = String(UUID().uuidString.lowercased().prefix(8))
        remoteSocket = "/tmp/amx-browser-\(suffix).sock"
        let stateDirectory = URL(fileURLWithPath: "/tmp/amx-browser-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        stateFile = stateDirectory.appending(path: "state.json")
        statusFixture = stateDirectory.appending(path: "status.jsonl")
    }

    deinit { stop() }

    func startForward() throws {
        guard !localSocket.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: remoteSocket)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", sshConfig, "-N", "-T", "-o", "ExitOnForwardFailure=yes",
            "-R", "\(remoteSocket):\(localSocket)", destination,
        ]
        let logURL = artifact.appending(path: "ssh-forward.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        forward = process
        forwardOutput = handle
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: remoteSocket), process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning, FileManager.default.fileExists(atPath: remoteSocket) else {
            throw BrowserE2EError.forwardFailed("reverse Unix socket did not appear")
        }
        try writeState()
    }

    func restartForward() throws {
        stopForward()
        try startForward()
    }

    func stopForward() {
        if let forward, forward.isRunning { forward.terminate() }
        if let forward { try? forward.waitUntilExitEventually(deadline: .seconds(5)) }
        forward = nil
        try? forwardOutput?.close()
        forwardOutput = nil
        try? FileManager.default.removeItem(atPath: remoteSocket)
    }

    func stop() {
        stopForward()
        try? FileManager.default.removeItem(at: stateFile.deletingLastPathComponent())
    }

    func runBrowserTask(url: String, timeout: Int) -> Task<Result, Error> {
        Task.detached { try self.runRemote(["browser-open", url, "--timeout", String(timeout)]) }
    }

    func runBrowser(url: String, timeout: Int) async throws -> Result {
        try await runBrowserTask(url: url, timeout: timeout).value
    }

    func writeStatusFixture() throws {
        try "{\"type\":\"agent-status\",\"source\":\"codex\",\"execution\":\"thinking\",\"eventID\":\"browser-e2e-status\"}\n"
            .write(to: statusFixture, atomically: true, encoding: .utf8)
    }

    func runStatusFixture() async throws -> Result {
        try await Task.detached { try self.runRemote(["--emit", self.statusFixture.path]) }.value
    }

    private func writeState() throws {
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: remoteSocket, token: token)
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    private func runRemote(_ helperArguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let remoteCommand =
            ([
                "env",
                "AWESOMUX_BRIDGE_STATE=\(stateFile.path)",
                "AWESOMUX_BRIDGE_SESSION=\(session)", helper,
            ] + helperArguments).map(Self.shellQuote).joined(separator: " ")
        process.arguments = ["-F", sshConfig, destination, remoteCommand]
        let capture = try captureOutput(of: process, deadline: .seconds(40))
        let result = Result(status: process.terminationStatus, stdout: capture.stdout, stderr: capture.stderr)
        resultLogLock.lock()
        defer { resultLogLock.unlock() }
        let line =
            "args=\(helperArguments) status=\(result.status) stdout=\(result.stdout.debugDescription) stderr=\(result.stderr.debugDescription)\n"
        let log = artifact.appending(path: "helper-results.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
        return result
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class BrowserHitReceiver: @unchecked Sendable {
    private let process: Process
    private let portFile: URL
    private let hitFile: URL
    private let logHandle: FileHandle
    private(set) var resolvedPort = 0

    init(artifact: URL) throws {
        portFile = artifact.appending(path: "browser-receiver-port")
        hitFile = artifact.appending(path: "browser-hit.txt")
        try? FileManager.default.removeItem(at: portFile)
        try? FileManager.default.removeItem(at: hitFile)
        let log = artifact.appending(path: "browser-receiver.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: log)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-u", "-c",
            """
            import http.server, pathlib, sys
            port_file, hit_file = map(pathlib.Path, sys.argv[1:3])
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    with hit_file.open('a') as hits:
                        hits.write(self.path + '\\n')
                    self.send_response(200); self.end_headers(); self.wfile.write(b'awesoMux browser E2E')
                def log_message(self, fmt, *args):
                    print(fmt % args, flush=True)
            server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
            port_file.write_text(str(server.server_port))
            server.serve_forever()
            """,
            portFile.path, hitFile.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
    }

    deinit { stop() }

    func port() async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) {
                resolvedPort = port
                return port
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw BrowserE2EError.receiverFailed
    }

    func waitForHit(expected: String) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let hits = try? String(contentsOf: hitFile, encoding: .utf8),
                hits.split(separator: "\n").contains(Substring(expected))
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? process.waitUntilExitEventually(deadline: .seconds(5))
        try? logHandle.close()
    }
}
