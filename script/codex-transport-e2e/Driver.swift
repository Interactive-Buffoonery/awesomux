import Darwin
import Foundation

@main
struct Driver {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args[1]
        if mode == "deinit" {
            let pid = try await releaseTransport(args)
            try await Task.sleep(for: .seconds(1.5))
            precondition(kill(pid, 0) == -1 && errno == ESRCH, "deinit child not reaped")
            print("deinit child reaped")
            return
        }
        let fixtureMode: String
        switch mode {
        case "close", "closed-send", "silent": fixtureMode = "resist"
        case "echo", "exit", "descendant": fixtureMode = mode
        default: fixtureMode = "backpressure"
        }
        let transport = try ProcessCodexAppServerTransport(
            executable: args[2], codexHome: args[4],
            arguments: [args[3], fixtureMode]
        )
        defer { transport.close() }
        _ = try await transport.receive() // Child installed its signal handler.
        let pid = Int32(try String(contentsOfFile: args[4] + "/pid", encoding: .utf8))!
        if ["close", "closed-send", "exit", "descendant"].contains(mode) {
            if mode == "exit" {
                let eof = try await transport.receive()
                precondition(eof == nil)
                try await Task.sleep(for: .milliseconds(100))
            }
            transport.close()
            transport.close()
            if mode == "closed-send" {
                do {
                    try await transport.send(Data("{}".utf8))
                    fatalError("send after close succeeded")
                } catch {
                    precondition(error as? CodexAppServerError == .connectionClosed)
                }
            }
            try await Task.sleep(for: .seconds(1.5))
            let gone = kill(pid, 0) == -1 && errno == ESRCH
            let descendantGone: Bool
            if mode == "descendant" {
                let descendantPID = Int32(try String(contentsOfFile: args[4] + "/descendant-pid", encoding: .utf8))!
                descendantGone = kill(descendantPID, 0) == -1 && errno == ESRCH
            } else {
                descendantGone = true
            }
            print("\(mode) child_gone=\(gone) descendant_gone=\(descendantGone)")
            exit(gone && descendantGone ? 0 : 1)
        }
        let client = ProcessCodexAppServerClient(
            transport: transport, requestTimeout: mode == "cancel" ? .seconds(20) : .milliseconds(300)
        )
        let started = ContinuousClock.now
        let operation = Task {
            try await client.configBatchWrite([
                CodexConfigWrite(keyPath: "hooks.state", value: .string(String(repeating: "x", count: 4 * 1024 * 1024)), mergeStrategy: .upsert)
            ], reloadUserConfig: true)
        }
        if mode == "cancel" {
            try await Task.sleep(for: .milliseconds(200))
            operation.cancel()
        }
        do {
            try await operation.value
            guard mode == "echo" else { fatalError("unexpected success") }
            let hooks = try await client.hooksList()
            precondition(hooks.isEmpty)
            print("echo config/batchWrite and hooks/list passed")
        } catch {
            print("\(mode) error=\(error) elapsed=\(started.duration(to: .now))")
            if mode == "timeout" || mode == "silent" {
                precondition(error as? CodexAppServerError == .requestTimedOut(method: mode == "silent" ? "initialize" : "config/batchWrite"))
            } else if mode == "cancel" {
                precondition(error is CancellationError || error as? CodexAppServerError == .connectionClosed)
            } else { throw error }
        }
        precondition(started.duration(to: .now) < .seconds(2))
        client.close()
        try await Task.sleep(for: .seconds(1.5))
        precondition(kill(pid, 0) == -1 && errno == ESRCH, "child not reaped")
    }

    private static func releaseTransport(_ args: [String]) async throws -> pid_t {
        let transport = try ProcessCodexAppServerTransport(
            executable: args[2], codexHome: args[4], arguments: [args[3], "resist"]
        )
        _ = try await transport.receive()
        return Int32(try String(contentsOfFile: args[4] + "/pid", encoding: .utf8))!
    }
}
