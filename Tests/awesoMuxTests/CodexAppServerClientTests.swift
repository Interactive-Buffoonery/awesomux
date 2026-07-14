import Foundation
import Testing
@testable import awesoMux

@Suite("ProcessCodexAppServerClient JSON-RPC")
struct ProcessCodexAppServerClientTests {
    @Test("decodes a hooks/list payload across every trustStatus variant")
    func decodesHooksListAcrossTrustVariants() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(Self.hooksListResponse(id: 1))
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        let hooks = try await client.hooksList()
        #expect(hooks.count == 4)
        #expect(hooks.map(\.trustStatus) == [.managed, .untrusted, .trusted, .modified])

        let trusted = try #require(hooks.first { $0.trustStatus == .trusted })
        #expect(trusted.pluginId == "awesomux-codex-status@awesomux")
        #expect(trusted.eventName == "session_start")
        #expect(trusted.isManaged == false)
        #expect(trusted.enabled)
        #expect(trusted.currentHash == "sha256:cccc")
        #expect(trusted.sourcePath == "/home/.codex/config.toml")
        #expect(trusted.source == "plugin")

        // The managed entry carries a null pluginId — the optional must
        // round-trip rather than fail decoding.
        let managed = try #require(hooks.first { $0.trustStatus == .managed })
        #expect(managed.pluginId == nil)

        // The request the client framed must be a well-formed hooks/list call.
        let sent = try #require(transport.sentMessages.first)
        let request = try JSONDecoder().decode(SentRequest.self, from: sent)
        #expect(request.jsonrpc == "2.0")
        #expect(request.id == 1)
        #expect(request.method == "hooks/list")
    }

    @Test("legacy and unfamiliar trust statuses remain decodable")
    func decodesCompatibleTrustStatuses() throws {
        let decoder = JSONDecoder()

        let firstSeen = try decoder.decode(HookTrustStatus.self, from: Data(#""first-seen""#.utf8))
        let changed = try decoder.decode(HookTrustStatus.self, from: Data(#""changed""#.utf8))
        let future = try decoder.decode(HookTrustStatus.self, from: Data(#""future-state""#.utf8))

        #expect(firstSeen == .untrusted)
        #expect(changed == .modified)
        #expect(future == .unknown("future-state"))
    }

    @Test("empty hooks/list data decodes to no hooks")
    func emptyDataDecodesToNoHooks() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":1,"result":{"data":[]}}"#)
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        let hooks = try await client.hooksList()
        #expect(hooks.isEmpty)
    }

    @Test("a hooks/list result of the wrong shape surfaces as malformedResponse")
    func malformedHooksListResultWraps() async throws {
        let transport = FakeCodexAppServerTransport()
        // `data` should be an array of cwd entries; a string is a valid JSON value
        // but the wrong shape, so the typed decode must fail and be wrapped rather
        // than crash.
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":1,"result":{"data":"nope"}}"#)
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        // The wrapped case is specifically malformedResponse, not a transport error.
        do {
            _ = try await client.hooksList()
            Issue.record("expected hooksList to throw on a wrong-shape result")
        } catch let error as CodexAppServerError {
            guard case .malformedResponse = error else {
                Issue.record("expected malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("multi-cwd hooks/list data flattens all hooks in stable order")
    func multiCwdHooksFlattenInStableOrder() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(Self.multiCwdHooksListResponse(id: 1))
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        let hooks = try await client.hooksList()
        #expect(hooks.map(\.key) == ["a:event:0:0", "b:event:0:0", "b:event:1:0"])
        #expect(hooks.map(\.sourcePath) == ["/a/config.toml", "/b/config.toml", "/b/config.toml"])
    }

    @Test("performs the initialize handshake before the first real method")
    func sendsInitializeBeforeFirstMethod() async throws {
        let transport = FakeCodexAppServerTransport()
        // The real server rejects every method until initialize is acknowledged.
        // initialize is id:1; the real method follows as id:2.
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        transport.enqueueResponse(Self.hooksListResponse(id: 2))
        let client = ProcessCodexAppServerClient(transport: transport)

        _ = try await client.hooksList()

        let sent = transport.sentMessages
        #expect(sent.count == 2)

        let initialize = try JSONDecoder().decode(SentInitialize.self, from: try #require(sent.first))
        #expect(initialize.method == "initialize")
        #expect(initialize.id == 1)
        #expect(initialize.params.clientInfo.name == "awesomux")
        #expect(!initialize.params.clientInfo.version.isEmpty)

        let method = try JSONDecoder().decode(SentRequest.self, from: sent[1])
        #expect(method.method == "hooks/list")
        #expect(method.id == 2)
    }

    @Test("initializes once, not before every method on the same session")
    func initializesOnlyOnce() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        transport.enqueueResponse(Self.hooksListResponse(id: 2))
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        let client = ProcessCodexAppServerClient(transport: transport)

        _ = try await client.hooksList()
        try await client.configBatchWrite(
            [CodexConfigWrite(keyPath: "hooks.state", value: .object([:]), mergeStrategy: .upsert)],
            reloadUserConfig: true
        )

        let methods = transport.sentMessages.compactMap {
            try? JSONDecoder().decode(SentRequest.self, from: $0).method
        }
        #expect(methods == ["initialize", "hooks/list", "config/batchWrite"])
    }

    @Test("serializes a config/batchWrite request with the edits wire key and reload flag")
    func serializesConfigBatchWrite() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        let write = CodexConfigWrite(
            keyPath: "hooks.state",
            value: .object([
                "config.toml:session_start:0:0": .object(["enabled": .bool(true)])
            ]),
            mergeStrategy: .upsert
        )
        try await client.configBatchWrite([write], reloadUserConfig: true)

        let sent = try #require(transport.sentMessages.first)

        // The live app-server spec names the edit list `edits`. The raw wire must
        // carry `params.edits` and must NOT carry the old `params.writes` key — a
        // real binary silently ignores `writes`, so the enable/disable RPC no-ops.
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        )
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["edits"] != nil)
        #expect(params["writes"] == nil)

        let request = try JSONDecoder().decode(SentBatchWrite.self, from: sent)
        #expect(request.method == "config/batchWrite")
        #expect(request.params.reloadUserConfig)
        #expect(request.params.edits.count == 1)
        #expect(request.params.edits[0].keyPath == "hooks.state")
        #expect(request.params.edits[0].mergeStrategy == .upsert)
        #expect(request.params.edits[0].value == write.value)
    }

    @Test("maps JSON-RPC method-not-found to a detectable degrade error")
    func mapsMethodNotFoundToMethodNotFound() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
        )
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        await #expect(throws: CodexAppServerError.methodNotFound(method: "hooks/list")) {
            _ = try await client.hooksList()
        }
    }

    @Test("EOF before a matching response surfaces connectionClosed")
    func eofSurfacesConnectionClosed() async throws {
        let transport = FakeCodexAppServerTransport()
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        await #expect(throws: CodexAppServerError.connectionClosed) {
            _ = try await client.hooksList()
        }
    }

    @Test("skips unrelated messages and correlates the matching id")
    func skipsUnrelatedMessages() async throws {
        let transport = FakeCodexAppServerTransport()
        // A notification (no id) and a stale-id response precede the real answer.
        transport.enqueueResponse(#"{"jsonrpc":"2.0","method":"some/notification"}"#)
        transport.enqueueResponse(#"{"jsonrpc":"2.0","id":99,"result":{"hooks":[]}}"#)
        transport.enqueueResponse(Self.hooksListResponse(id: 1))
        let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

        let hooks = try await client.hooksList()
        #expect(hooks.count == 4)
    }

    @Test("a silent server that never replies surfaces requestTimedOut, not a hang")
    func silentServerSurfacesRequestTimedOut() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.blockReceiveUntilClosed()
        let client = ProcessCodexAppServerClient(
            transport: transport,
            // ponytail: the production `request()` already closes the
            // .connectionClosed/.requestTimedOut race deterministically via
            // TimeoutFlag (see ProcessCodexAppServerClient.request), so a short
            // deadline isn't racing correctness — but under a full parallel
            // suite run (1750+ tests), scheduler contention can delay this
            // actor enough that a tight 200ms budget adds wall-clock flake risk
            // for no test-value gained. Widened for headroom (INT-590); revisit
            // down only if suite runtime actually matters.
            requestTimeout: .milliseconds(1500),
            assumeInitialized: true
        )

        // The server accepted the request but never answers and never EOFs; the
        // bounded deadline must turn that into a thrown error the caller can
        // degrade on, not an indefinite block on the actor.
        await #expect(throws: CodexAppServerError.requestTimedOut(method: "hooks/list")) {
            _ = try await client.hooksList()
        }
        #expect(transport.isClosed)
    }

    @Test("cancelling a pending request closes the transport instead of wedging")
    func cancellationClosesTransport() async throws {
        let transport = FakeCodexAppServerTransport()
        // Model the real stdio transport: the parked read is unblocked only by
        // close(), never by cancellation alone.
        transport.blockReceiveUntilClosed()
        let client = ProcessCodexAppServerClient(
            transport: transport,
            // Long enough that the deadline child cannot be what unblocks us — only
            // the cancellation handler can close the transport in this window.
            requestTimeout: .seconds(3600),
            assumeInitialized: true
        )

        let task = Task { try await client.hooksList() }
        // Wait until the request has been sent and the read is parked.
        while transport.sentMessages.isEmpty {
            await Task.yield()
        }
        task.cancel()
        // Without the cancellation handler closing the transport, the parked read
        // keeps the task group from returning and this await would hang forever.
        _ = try? await task.value
        #expect(transport.isClosed)
    }

    @Test("close tears down the transport")
    func closeTearsDownTransport() async throws {
        let transport = FakeCodexAppServerTransport()
        let client = ProcessCodexAppServerClient(transport: transport)
        #expect(!transport.isClosed)
        client.close()
        #expect(transport.isClosed)
    }

    @Test("dropping the client tears down the transport on deinit")
    func deinitTearsDownTransport() async throws {
        let transport = FakeCodexAppServerTransport()
        var client: ProcessCodexAppServerClient? = ProcessCodexAppServerClient(transport: transport)
        #expect(client != nil)
        // The transport holds no back-reference, so dropping the last client
        // reference must run deinit, which closes the transport.
        client = nil
        #expect(transport.isClosed)
    }

    @Test("non-method-not-found RPC errors surface as rpcError")
    func otherRPCErrorSurfacesAsRPCError() async throws {
        let transport = FakeCodexAppServerTransport()
        transport.enqueueResponse(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"boom"}}"#
        )
        let client = ProcessCodexAppServerClient(transport: transport)

        await #expect(throws: CodexAppServerError.rpcError(code: -32000, message: "boom")) {
            _ = try await client.hooksList()
        }
    }
}

@Suite("ProcessCodexAppServerTransport executable resolution")
struct ProcessCodexAppServerTransportResolutionTests {
    @Test("a bare name absent from the search path throws appServerUnavailable")
    func bareNameAbsentThrowsAppServerUnavailable() throws {
        let executableName = "codex-\(UUID().uuidString)"
        #expect(throws: CodexAppServerError.appServerUnavailable(
            reason: "codex executable not found at \(executableName)"
        )) {
            _ = try ProcessCodexAppServerTransport(
                executable: executableName,
                codexHome: FileManager.default.temporaryDirectory.path,
                defaultPath: "/no/such/path"
            )
        }
    }

    @Test("a bare name present on the search path spawns")
    func bareNamePresentSpawns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-codex-transport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "codex")
        _ = FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // Resolution against the search path must succeed; the transport spawns the
        // (immediately-exiting) process without throwing.
        let transport = try ProcessCodexAppServerTransport(
            executable: "codex",
            codexHome: FileManager.default.temporaryDirectory.path,
            defaultPath: directory.path
        )
        transport.close()
    }
}

@Suite("StubCodexAppServerClient")
struct StubCodexAppServerClientTests {
    @Test("returns the canned hooks/list payload")
    func returnsCannedHooks() async throws {
        let client = StubCodexAppServerClient()
        let entry = HookEntry(
            key: "k", eventName: "session_start", isManaged: false,
            pluginId: "awesomux-codex-status@awesomux", enabled: true,
            currentHash: "sha256:1", trustStatus: .trusted,
            sourcePath: "/c.toml", source: "plugin"
        )
        client.setHooksList([entry])

        let hooks = try await client.hooksList()
        #expect(hooks == [entry])
    }

    @Test("propagates a canned hooks/list failure")
    func propagatesCannedFailure() async throws {
        let client = StubCodexAppServerClient()
        client.setHooksListFailure(.methodNotFound(method: "hooks/list"))

        await #expect(throws: CodexAppServerError.methodNotFound(method: "hooks/list")) {
            _ = try await client.hooksList()
        }
    }

    @Test("records configBatchWrite calls")
    func recordsBatchWrites() async throws {
        let client = StubCodexAppServerClient()
        let write = CodexConfigWrite(
            keyPath: "hooks.state",
            value: .object(["k": .object(["enabled": .bool(true)])]),
            mergeStrategy: .upsert
        )
        try await client.configBatchWrite([write], reloadUserConfig: true)

        #expect(client.batchWriteCalls == [
            StubCodexAppServerClient.BatchWriteCall(writes: [write], reloadUserConfig: true)
        ])
    }
}

// MARK: - Canned payloads

private extension ProcessCodexAppServerClientTests {
    /// Mirrors the real app-server `hooks/list` shape: hooks nest under
    /// `result.data[].hooks` (a per-cwd array), and each hook object carries the
    /// extra wire fields the decoder ignores (`handlerType`, `matcher`, `command`,
    /// `timeoutSec`, `displayOrder`) plus omits `warnings`/`errors`, which live on
    /// the `data` wrapper, not the hook.
    static func hooksListResponse(id: Int) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"result":{"data":[{"cwd":"/home/project","hooks":[
          {"key":"config.toml:session_start:0:0","eventName":"session_start",\
        "handlerType":"command","matcher":null,"command":"helper","timeoutSec":5,\
        "displayOrder":0,"isManaged":true,\
        "pluginId":null,"enabled":true,"currentHash":"sha256:aaaa","trustStatus":"managed",\
        "sourcePath":"/home/.codex/config.toml","source":"managed"},
          {"key":"config.toml:session_start:1:0","eventName":"session_start","isManaged":false,\
        "pluginId":"awesomux-codex-status@awesomux","enabled":true,"currentHash":"sha256:bbbb",\
        "trustStatus":"untrusted","sourcePath":"/home/.codex/config.toml","source":"user"},
          {"key":"config.toml:session_start:2:0","eventName":"session_start","isManaged":false,\
        "pluginId":"awesomux-codex-status@awesomux","enabled":true,"currentHash":"sha256:cccc",\
        "trustStatus":"trusted","sourcePath":"/home/.codex/config.toml","source":"plugin"},
          {"key":"config.toml:session_start:3:0","eventName":"session_start","isManaged":false,\
        "pluginId":"awesomux-codex-status@awesomux","enabled":true,"currentHash":"sha256:dddd",\
        "trustStatus":"modified","sourcePath":"/home/.codex/config.toml","source":"user"}
        ],"warnings":[],"errors":[]}]}}
        """
    }

    static func multiCwdHooksListResponse(id: Int) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"result":{"data":[
          {"cwd":"/b","hooks":[
            {"key":"b:event:1:0","eventName":"event","isManaged":false,"pluginId":"p","enabled":true,\
        "currentHash":"sha256:b1","trustStatus":"trusted","sourcePath":"/b/config.toml","source":"plugin"},
            {"key":"b:event:0:0","eventName":"event","isManaged":false,"pluginId":"p","enabled":true,\
        "currentHash":"sha256:b0","trustStatus":"trusted","sourcePath":"/b/config.toml","source":"plugin"}
          ],"warnings":[],"errors":[]},
          {"cwd":"/a","hooks":[
            {"key":"a:event:0:0","eventName":"event","isManaged":false,"pluginId":"p","enabled":true,\
        "currentHash":"sha256:a0","trustStatus":"trusted","sourcePath":"/a/config.toml","source":"plugin"}
          ],"warnings":[],"errors":[]}
        ]}}
        """
    }
}

// MARK: - Sent-request decoders

private struct SentRequest: Decodable {
    let jsonrpc: String
    let id: Int
    let method: String
}

private struct SentInitialize: Decodable {
    let id: Int
    let method: String
    let params: Params

    struct Params: Decodable {
        let clientInfo: ClientInfo
    }

    struct ClientInfo: Decodable {
        let name: String
        let title: String
        let version: String
    }
}

private struct SentBatchWrite: Decodable {
    let method: String
    let params: Params

    struct Params: Decodable {
        let edits: [CodexConfigWrite]
        let reloadUserConfig: Bool
    }
}
