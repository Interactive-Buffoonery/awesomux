import AwesoMuxCore
import AwesoMuxLocalAPI
import Darwin
import Foundation
import Synchronization

@MainActor
final class TerminalBrowserBridge {
    private let listener: DispatchSourceRead
    let socketPath: String

    struct Request: Decodable, Sendable {
        struct Pane: Codable, Equatable, Sendable {
            let id: UUID
            let tab: UUID
        }

        struct Parameters: Decodable, Sendable {
            var protocolVersion: Int?
            var tty: String?
            var from: Pane?
            var direction: String?
            var command: [String]?

            enum CodingKeys: String, CodingKey {
                case protocolVersion = "protocol"
                case tty, from, direction, command
            }
        }

        struct Caller: Decodable, Sendable {
            let pid: pid_t
            let cwd: String
        }
        let caller: Caller?
        let id: String
        let method: String
        let params: Parameters
    }

    enum SplitPreparation: Sendable {
        case launch(command: String, directory: String)
        case rejected(String)
    }

    init(
        approvedExecutable: String,
        handle: @escaping @MainActor @Sendable (Request, SplitPreparation?, ContinuousClock.Instant) async -> [String: Any]
    ) throws {
        let directory = URL(fileURLWithPath: "/tmp/amx-browser-\(UUID().uuidString)")
        socketPath = directory.appendingPathComponent("api").path
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var ready = false
        defer {
            if !ready {
                if fd >= 0 { close(fd) }
                try? FileManager.default.removeItem(at: directory)
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = socketPath.utf8CString
        guard fd >= 0, path.count <= MemoryLayout.size(ofValue: address.sun_path),
            fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0
        else { throw POSIXError(.EIO) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EIO) }
        let queue = DispatchQueue(label: "awesomux.terminal-browser", qos: .utility)
        let clients = DispatchSemaphore(value: 4)
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler(handler: { @Sendable in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0, clients.wait(timeout: .now()) == .success else {
                close(client)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                defer { clients.signal() }
                Self.serveRequest(client, approvedExecutable: approvedExecutable, handle: handle)
            }
        })
        listener.setCancelHandler(handler: { @Sendable in
            close(fd)
            try? FileManager.default.removeItem(at: directory)
        })
        ready = true
        listener.resume()
    }

    deinit { listener.cancel() }

    static func response(
        to request: Request, preparation: SplitPreparation?, deadline: ContinuousClock.Instant, store: SessionStore, runtime: GhosttyRuntime
    ) async -> [String: Any] {
        func error(_ message: String) -> [String: Any] { ["error": ["message": message]] }
        if request.method == "hello" {
            guard request.params.protocolVersion == 1 else { return error("Unsupported protocol") }
            return ["result": ["name": "awesoMux", "methods": ["getCurrentPane", "split"]]]
        }

        guard let tty = request.params.tty,
            let device = terminalDevice(tty),
            let caller = request.caller,
            terminalDevice(pid: caller.pid) == device,
            let match = runtime.localAPIProcessSources().first(where: { _, source in
                guard case .foreground(let pid) = source else { return false }
                return terminalDevice(pid: pid) == device
            }),
            let workspaceID = store.localAPIWorkspaceIDs()[match.key],
            let workspace = store.session(id: workspaceID),
            let source = workspace.layout.pane(id: match.key),
            case .local = source.executionPlan,
            !runtime.isCommandBridgeEnabled
        else {
            if request.method == "getCurrentPane" { return ["result": ["pane": NSNull()]] }
            return error("The caller must be in a local shell pane with the command bridge disabled")
        }

        let pane = Request.Pane(id: source.id, tab: workspace.id)
        if request.method == "getCurrentPane" {
            return ["result": ["pane": ["id": pane.id.uuidString, "tab": pane.tab.uuidString]]]
        }

        guard request.method == "split", request.params.from == pane,
            store.selectedSessionID == workspace.id, workspace.activePaneID == source.id,
            let preparation
        else { return error("Only the active local pane can open a Terminal Browser split") }

        if case .rejected(let message) = preparation { return error(message) }
        guard case .launch(let command, let directory) = preparation,
            .now < deadline,
            let newPane = store.splitActivePane(orientation: .vertical, in: workspace.id, workingDirectory: directory)
        else { return error("Could not create the terminal split") }
        runtime.noteInteractiveSplit(newPane, from: source.id)
        let created = await withCheckedContinuation { completion in
            runtime.terminalBrowserLaunchCommands[newPane] = (command, deadline, completion)
            // Expire hidden panes even when their surface creation never runs.
            let duration = ContinuousClock.now.duration(to: deadline).components
            let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining)) { [weak runtime] in
                runtime?.terminalBrowserLaunchCommands.removeValue(forKey: newPane)?.completion.resume(returning: false)
            }
        }
        return created ? ["result": [String: String]()] : error("Could not start Terminal Browser in the new pane")
    }

    private nonisolated static func serveRequest(
        _ fd: Int32,
        approvedExecutable: String,
        handle: @escaping @MainActor @Sendable (Request, SplitPreparation?, ContinuousClock.Instant) async -> [String: Any]
    ) {
        defer { close(fd) }

        var uid: uid_t = 0
        var gid: gid_t = 0
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        var noSignal: Int32 = 1
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 0,
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { return }

        let waitDeadline = DispatchTime.now() + 3
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let io = LocalAPIIO(deadline: deadline, cancelled: { false })
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= 32_768 {
            guard (try? io.wait(fd, events: Int16(POLLIN))) != nil else { return }
            let count = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            guard let newline = buffer.firstIndex(of: 10) else { continue }
            guard newline <= 32_768,
                let request = try? JSONDecoder().decode(Request.self, from: buffer.prefix(upTo: newline)),
                request.caller?.pid == peer
            else { return }

            let preparation = request.method == "split" ? prepareSplit(request, executable: approvedExecutable) : nil
            // The main actor never waits for socket I/O.
            let finished = DispatchSemaphore(value: 0)
            let reply = Mutex<Data?>(nil)
            Task { @MainActor in
                defer { finished.signal() }
                guard .now < deadline else { return }
                var response = await handle(request, preparation, deadline)
                response["id"] = request.id
                guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
                data.append(10)
                reply.withLock { $0 = data }
            }
            guard finished.wait(timeout: waitDeadline) == .success,
                let data = reply.withLock({ $0 })
            else { return }
            var offset = 0
            while offset < data.count {
                guard (try? io.wait(fd, events: Int16(POLLOUT))) != nil else { return }
                let written = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                if written < 0, errno == EAGAIN || errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
            return
        }
    }

    private nonisolated static func prepareSplit(_ request: Request, executable: String) -> SplitPreparation {
        guard let tty = request.params.tty,
            let caller = request.caller, let device = terminalDevice(tty), terminalDevice(pid: caller.pid) == device,
            request.params.direction == "right",
            let command = request.params.command, command.count == 5,
            executablePath(command[0]) == executable,
            command[1] == "open", let target = normalizedTarget(command[2]),
            command[3] == "--split-dir=right", command[4] == "--parent-tty=\(tty)"
        else { return .rejected("Unsupported Terminal Browser split request") }

        guard let directory = WorkingDirectoryValidator.validatedStartupDirectory(caller.cwd) else {
            return .rejected("Change to a directory you own before opening a Terminal Browser split")
        }
        // Ghostty adds its own exec prefix to startup commands on macOS.
        let startupCommand = [executable, "open", target, command[3], command[4]].map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        return .launch(command: startupCommand, directory: directory)
    }

    nonisolated static func executablePath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return nil }
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isExecutableFile(atPath: resolved.path)
        else { return nil }
        return resolved.path
    }

    private nonisolated static func normalizedTarget(_ target: String) -> String? {
        guard !target.isEmpty, !target.hasPrefix("-"),
            !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        if target.hasPrefix("/") { return target.hasPrefix("//") ? nil : target }
        let url = target.contains("://") ? target : "http://" + target
        guard let parts = URLComponents(string: url),
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil,
            parts.scheme == "http" || parts.scheme == "https"
        else { return nil }
        return parts.url?.absoluteString
    }

    nonisolated static func terminalDevice(_ tty: String?) -> UInt32? {
        guard let tty, tty.hasPrefix("/dev/tty"), !tty.dropFirst(5).contains("/"),
            !tty.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        var info = stat()
        guard lstat(tty, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }

    nonisolated static func terminalDevice(pid: pid_t) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid()
        else { return nil }
        return info.e_tdev
    }
}
