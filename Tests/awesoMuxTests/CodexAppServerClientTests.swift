import Foundation
import Testing
@testable import awesoMux

@Suite("ProcessCodexAppServerClient JSON-RPC")
struct ProcessCodexAppServerClientTests {
    enum DecodeTrustStatusesCase: String, CaseIterable {
        case decodesHooksListAcrossTrustVariants
        case decodesCompatibleTrustStatuses
    }

    @Test(arguments: DecodeTrustStatusesCase.allCases)
    func decodeTrustStatuses(_ scenario: DecodeTrustStatusesCase) async throws {
        switch scenario {
        case .decodesHooksListAcrossTrustVariants:
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
        case .decodesCompatibleTrustStatuses:
            let decoder = JSONDecoder()

            let firstSeen = try decoder.decode(HookTrustStatus.self, from: Data(#""first-seen""#.utf8))
            let changed = try decoder.decode(HookTrustStatus.self, from: Data(#""changed""#.utf8))
            let future = try decoder.decode(HookTrustStatus.self, from: Data(#""future-state""#.utf8))

            #expect(firstSeen == .untrusted)
            #expect(changed == .modified)
            #expect(future == .unknown("future-state"))
        }
    }

    enum MapFailuresCase: String, CaseIterable {
        case malformedHooksListResultWraps
        case mapsMethodNotFoundToMethodNotFound
        case eofSurfacesConnectionClosed
        case otherRPCErrorSurfacesAsRPCError
    }

    @Test(arguments: MapFailuresCase.allCases)
    func mapFailures(_ scenario: MapFailuresCase) async throws {
        switch scenario {
        case .malformedHooksListResultWraps:
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
        case .mapsMethodNotFoundToMethodNotFound:
            let transport = FakeCodexAppServerTransport()
            transport.enqueueResponse(
                #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
            )
            let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

            await #expect(throws: CodexAppServerError.methodNotFound(method: "hooks/list")) {
                _ = try await client.hooksList()
            }
        case .eofSurfacesConnectionClosed:
            let transport = FakeCodexAppServerTransport()
            let client = ProcessCodexAppServerClient(transport: transport, assumeInitialized: true)

            await #expect(throws: CodexAppServerError.connectionClosed) {
                _ = try await client.hooksList()
            }
        case .otherRPCErrorSurfacesAsRPCError:
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

}

// MARK: - Sent-request decoders

private struct SentRequest: Decodable {
    let jsonrpc: String
    let id: Int
    let method: String
}
