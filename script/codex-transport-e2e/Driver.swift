import Darwin
import Foundation

@main
struct Driver {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args[1]
        let transport = try ProcessCodexAppServerTransport(
            executable: args[2], codexHome: args[4],
            arguments: [args[3], mode == "close" ? "resist" : mode == "echo" ? "echo" : "backpressure"]
        )
        defer { transport.close() }
        _ = try await transport.receive() // Child installed its signal handler.
        let pid = Int32(try String(contentsOfFile: args[4] + "/pid", encoding: .utf8))!
        if mode == "close" {
            transport.close()
            transport.close()
            try await Task.sleep(for: .seconds(1.5))
            let gone = kill(pid, 0) == -1 && errno == ESRCH
            print("close child_gone=\(gone)")
            exit(gone ? 0 : 1)
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
            if mode == "timeout" {
                precondition(error as? CodexAppServerError == .requestTimedOut(method: "config/batchWrite"))
            } else if mode == "cancel" {
                precondition(error is CancellationError || error as? CodexAppServerError == .connectionClosed)
            } else { throw error }
        }
        precondition(started.duration(to: .now) < .seconds(2))
        client.close()
        try await Task.sleep(for: .seconds(1.5))
        precondition(kill(pid, 0) == -1 && errno == ESRCH, "child not reaped")
    }
}
