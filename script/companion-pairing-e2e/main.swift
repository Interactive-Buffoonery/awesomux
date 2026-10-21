import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct PairingLink {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let macFingerprint: Data
    let secret: String
    let macName: String
    let transport: String
    let advertisedRoutes: [String: String]

    init(_ rawValue: String) throws {
        let link = try CompanionPairingLinkV2(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let rawHost = link.routes.lan ?? link.routes.tailscale,
            let port = NWEndpoint.Port(rawValue: link.routes.p),
            let fingerprint = Data(base64URL: link.macFingerprint), fingerprint.count == 32,
            let secretData = Data(base64URL: link.secret), secretData.count == 32,
            !link.macName.isEmpty
        else { throw E2EFailure("invalid pairing field") }
        let transport = link.routes.lan != nil ? "lan" : "tailscale"
        host = NWEndpoint.Host(rawHost)
        self.port = port
        macFingerprint = fingerprint
        self.secret = link.secret
        self.macName = link.macName
        self.transport = transport
        advertisedRoutes = ["lan": link.routes.lan, "tailscale": link.routes.tailscale].compactMapValues { $0 }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.withLock {
            if resumed { return false }; resumed = true; return true
        }
    }
}

private final class PeerCertificateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SecCertificate?
    func store(_ certificate: SecCertificate) { lock.withLock { if value == nil { value = certificate } } }
    var certificate: SecCertificate? { lock.withLock { value } }
}

private struct OpenedConnection {
    let connection: NWConnection
    let macSPKI: Data
}

private enum CompanionClient {
    static func open(link: PairingLink, identity: E2EClientIdentity) async throws -> OpenedConnection {
        let tls = NWProtocolTLS.Options()
        guard let protocolIdentity = sec_identity_create(identity.identity) else {
            throw E2EFailure("could not create the TLS identity")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let expected = link.macFingerprint
        let peerCertificate = PeerCertificateBox()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                    let leaf = chain.first,
                    let spki = try? E2ECertificate.subjectPublicKeyInfo(for: leaf)
                else {
                    complete(false)
                    return
                }
                peerCertificate.store(leaf)
                complete(Data(SHA256.hash(data: spki)) == expected)
            },
            DispatchQueue(label: "awesomux.companion-e2e.verify")
        )
        let connection = NWConnection(host: link.host, port: link.port, using: NWParameters(tls: tls))
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: E2EFailure("TLS connection was cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "awesomux.companion-e2e.connection"))
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: E2EFailure("TLS connection timed out"))
            }
        }
        guard let certificate = peerCertificate.certificate else { throw E2EFailure("Mac certificate was unavailable") }
        return OpenedConnection(connection: connection, macSPKI: try E2ECertificate.subjectPublicKeyInfo(for: certificate))
    }

    static func exchange(_ object: [String: Any], connection: NWConnection) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await sendFrame(data, connection: connection)
        return try await receiveObject(connection: connection)
    }

    static func receiveObject(connection: NWConnection) async throws -> [String: Any] {
        let data = try await readFrame(connection)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2EFailure("response was not a JSON object")
        }
        return object
    }

    private static func sendFrame(_ data: Data, connection: NWConnection) async throws {
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private static func readFrame(_ connection: NWConnection) async throws -> Data {
        let header = try await receive(connection, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= LocalAPIContract.maximumResponseBytes else {
            throw E2EFailure("response frame length is invalid")
        }
        return try await receive(connection, count: Int(length))
    }

    private static func receive(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: E2EFailure("peer closed the connection"))
                } else {
                    continuation.resume(throwing: E2EFailure("short response frame"))
                }
            }
        }
    }
}

@main
struct CompanionPairingE2E {
    @MainActor
    static func main() async {
        do {
            if try handleFixtureCommand() { return }
            let invocation = try invocation()
            if let cleanupResult = invocation.cleanupResult {
                try cleanup(resultFile: cleanupResult)
                print("cleanup=revoked")
                return
            }
            guard let rawLink = invocation.link else { throw E2EFailure("pairing link is missing") }
            guard let expectedProfile = invocation.profile else { throw E2EFailure("development profile is missing") }
            let link = try PairingLink(rawLink)
            let identity = try E2EClientIdentity.make()
            defer { identity.cleanup() }
            print("endpoint=\(link.host):\(link.port) transport=\(link.transport) mac=\(link.macName)")
            print("client_spki_sha256=\(Data(SHA256.hash(data: identity.spki)).base64URL)")

            try await verifyWrongSecretIsDenied(link: link, identity: identity)
            let connectionID = try await pair(link: link, identity: identity)
            guard let resultFile = invocation.resultFile else { throw E2EFailure("the result file is missing") }
            try writeCleanupResult(profile: expectedProfile, connectionID: connectionID, to: resultFile)
            try await verifyMacPin(link: link, identity: identity)
            var profile: String?
            for operation in ["get_connection_status", "list_agents", "list_panes", "get_attention_events"] {
                var request: [String: Any] = [
                    "schemaVersion": 1,
                    "requestID": UUID().uuidString.lowercased(),
                    "operation": operation,
                    "connectionID": connectionID,
                ]
                if operation == "get_attention_events" { request["limit"] = 100 }
                let response = try await call(request, link: link, identity: identity)
                guard response["error"] == nil else { throw E2EFailure("\(operation) was denied") }
                if operation == "get_connection_status" {
                    profile = response["profile"] as? String
                    guard let routes = response["routes"] as? [String: Any], routes["v"] as? Int == 2,
                        routes["p"] as? Int == Int(link.port.rawValue),
                        link.advertisedRoutes.allSatisfy({ routes[$0.key] as? String == $0.value })
                    else { throw E2EFailure("status did not report the advertised v2 routes") }
                    print("advertised_routes=\(link.advertisedRoutes.keys.sorted().joined(separator: ","))")
                    guard response["terminalPreviewAllowed"] as? Bool == true else {
                        throw E2EFailure("new pairing did not retain disclosed preview consent")
                    }
                }
                if operation == "list_panes" {
                    let encoded = try JSONSerialization.data(withJSONObject: response)
                    let roster = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: encoded)
                    guard let workspaces = roster.workspaces, !workspaces.isEmpty,
                        workspaces.contains(where: { $0.panes.contains(where: { $0.kind == "terminal" }) })
                    else { throw E2EFailure("list_panes did not return terminal workspaces") }
                    if let fixtureSnapshot = invocation.fixtureSnapshot {
                        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixtureSnapshot)))
                        guard let snapshot = object as? [String: Any], let groups = snapshot["groups"] as? [[String: Any]] else {
                            throw E2EFailure("native fixture snapshot is invalid")
                        }
                        let sessions = groups.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
                        let expectedIDs = sessions.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
                        guard expectedIDs.count == 2,
                            workspaces.compactMap({ UUID(uuidString: $0.workspaceID) }) == expectedIDs,
                            workspaces.allSatisfy({ $0.panes.count == 1 && $0.panes[0].kind == "terminal" })
                        else { throw E2EFailure("pane roster did not match the two owned native fixtures") }
                    }
                    for pane in workspaces.flatMap(\.panes) {
                        guard pane.lastOutputLine.map({ !$0.contains(where: \.isNewline) && $0.utf8.count <= 512 }) ?? true,
                            pane.kind == "terminal" || pane.lastOutputLine == nil
                        else { throw E2EFailure("list_panes returned an invalid preview") }
                    }
                    // Do not retain terminal content in the E2E log.
                    print("list_panes=validated workspaces=\(workspaces.count) panes=\(workspaces.flatMap(\.panes).count)")
                } else {
                    printJSON(label: operation, object: response)
                }
            }
            let denied = try await call(
                [
                    "schemaVersion": 1,
                    "requestID": UUID().uuidString.lowercased(),
                    "operation": "get_agent_context",
                    "connectionID": connectionID,
                    "paneID": UUID().uuidString.lowercased(),
                    "targetVersion": UUID().uuidString.lowercased(),
                    "limit": 1,
                    "source": "transcript",
                ], link: link, identity: identity)
            guard denied["error"] as? String == "permission_denied" else {
                throw E2EFailure("get_agent_context was not denied")
            }
            printJSON(label: "get_agent_context_denied", object: denied)
            guard profile == expectedProfile else { throw E2EFailure("the response profile did not match the staged build") }
            func request(_ operation: String, id: String? = nil) -> sending [String: Any] {
                [
                    "schemaVersion": 1, "requestID": UUID().uuidString.lowercased(),
                    "operation": operation, "connectionID": id ?? connectionID,
                ]
            }
            for allowed in [false, true, true] {
                var mutation = request("set_terminal_preview")
                mutation["terminalPreviewAllowed"] = allowed
                let receipt = try await call(mutation, link: link, identity: identity)
                guard receipt["error"] == nil, receipt["terminalPreviewAllowed"] as? Bool == allowed,
                    receipt["workspaces"] == nil, receipt["agents"] == nil
                else { throw E2EFailure("self preview permission update was not acknowledged") }
                let status = try await call(request("get_connection_status"), link: link, identity: identity)
                guard status["terminalPreviewAllowed"] as? Bool == allowed else {
                    throw E2EFailure("preview permission readback did not match")
                }
                let roster = try await call(request("list_panes"), link: link, identity: identity)
                guard roster["error"] == nil, let workspaces = roster["workspaces"] as? [[String: Any]] else {
                    throw E2EFailure("preview toggle lost status roster")
                }
                if !allowed {
                    for pane in workspaces.flatMap({ $0["panes"] as? [[String: Any]] ?? [] }) {
                        guard pane["lastOutputLine"] == nil else { throw E2EFailure("disabled phone received terminal preview") }
                    }
                }
                print("set_terminal_preview=validated allowed=\(allowed)")
            }
            for invalidValue: Any in [NSNull(), 1, "true"] {
                var malformed = request("set_terminal_preview")
                malformed["terminalPreviewAllowed"] = invalidValue
                let deniedMutation = try await call(malformed, link: link, identity: identity)
                guard deniedMutation["error"] as? String == "invalid_request" else {
                    throw E2EFailure("malformed preview permission was accepted")
                }
            }
            var wrongPhone = request("set_terminal_preview", id: UUID().uuidString)
            wrongPhone["terminalPreviewAllowed"] = true
            let deniedPhone = try await call(wrongPhone, link: link, identity: identity)
            guard deniedPhone["error"] as? String == "permission_denied" else {
                throw E2EFailure("preview permission changed another phone")
            }
            for (operation, id, expected) in [
                ("unpair", UUID().uuidString, "permission_denied"),
                ("unknown_companion_operation", connectionID, "unsupported_operation"),
            ] {
                let response = try await call(request(operation, id: id), link: link, identity: identity)
                guard response["error"] as? String == expected else {
                    throw E2EFailure("\(operation) did not return \(expected)")
                }
                printJSON(label: "\(operation)_denied", object: response)
            }
            var invalidPaneList = request("list_panes")
            invalidPaneList["limit"] = 1
            let invalidRoster = try await call(invalidPaneList, link: link, identity: identity)
            guard invalidRoster["error"] as? String == "invalid_request" else {
                throw E2EFailure("list_panes arguments did not return invalid_request")
            }
            var invalidUnpair = request("unpair")
            invalidUnpair["limit"] = 1
            let invalid = try await call(invalidUnpair, link: link, identity: identity)
            printJSON(label: "unpair_arguments", object: invalid)
            guard invalid["error"] as? String == "invalid_request" else {
                throw E2EFailure("unpair arguments did not return invalid_request")
            }
            let stillPaired = try await call(request("get_connection_status"), link: link, identity: identity)
            guard stillPaired["connectionStatus"] as? String == "connected" else {
                throw E2EFailure("denied requests revoked the phone")
            }
            var rename = request("rename_pane")
            rename["workspaceID"] = UUID().uuidString
            rename["paneID"] = UUID().uuidString
            rename["title"] = "E2E pane"
            let renameDenied = try await call(rename, link: link, identity: identity)
            guard renameDenied["error"] as? String == "permission_denied" else {
                throw E2EFailure("a newly paired phone could rename without Mac opt-in")
            }
            printJSON(label: "rename_default_denied", object: renameDenied)
            for key in ["workspaceID", "paneID", "title"] {
                for value in [NSNull(), 1, true] as [Any] {
                    var malformed = rename
                    malformed[key] = value
                    let result = try await call(malformed, link: link, identity: identity)
                    guard result["error"] as? String == "invalid_request" else {
                        throw E2EFailure("rename accepted malformed \(key)")
                    }
                }
                var missing = rename
                missing.removeValue(forKey: key)
                let result = try await call(missing, link: link, identity: identity)
                guard result["error"] as? String == "invalid_request" else {
                    throw E2EFailure("rename accepted missing \(key)")
                }
            }
            for key in ["limit", "cursor", "targetVersion", "source"] {
                var extra = rename
                extra[key] = "unexpected"
                let result = try await call(extra, link: link, identity: identity)
                guard result["error"] as? String == "invalid_request" else {
                    throw E2EFailure("rename accepted unrelated \(key)")
                }
            }
            for operation in ["get_connection_status", "list_agents", "unpair"] {
                var unrelated = request(operation)
                unrelated["title"] = "E2E pane"
                let result = try await call(unrelated, link: link, identity: identity)
                guard result["error"] as? String == "invalid_request" else {
                    throw E2EFailure("\(operation) accepted rename arguments")
                }
            }
            print("rename_arguments=invalid_request")
            // Keep a TLS session open across revocation to exercise stale authorization too.
            let stale = try await CompanionClient.open(link: link, identity: identity).connection
            defer { stale.cancel() }
            let unpaired = try await call(request("unpair"), link: link, identity: identity)
            guard unpaired["error"] == nil, unpaired["profile"] as? String == expectedProfile,
                unpaired["appInstanceID"] != nil, unpaired["capturedAt"] != nil
            else { throw E2EFailure("self-unpair was not acknowledged") }
            printJSON(label: "self_unpair", object: unpaired)
            do {
                let response = try await CompanionClient.exchange(request("list_panes"), connection: stale)
                guard response["error"] != nil else { throw E2EFailure("revoked connection returned data") }
                printJSON(label: "revoked_connection", object: response)
            } catch let error as E2EFailure where error.description == "revoked connection returned data" {
                throw error
            } catch {
                print("revoked_connection=closed")
            }
            do {
                let response = try await call(request("list_panes"), link: link, identity: identity)
                guard response["error"] != nil else { throw E2EFailure("revoked phone reconnected") }
            } catch let error as E2EFailure where error.description == "revoked phone reconnected" {
                throw error
            } catch {
                print("revoked_reconnect=denied")
            }
            try writeCleanupResult(profile: expectedProfile, connectionID: connectionID, to: resultFile, expectRevoked: true)
            print(
                "PASS: pairing, reads, context denial, invalid and unknown requests, rename opt-in denial and argument validation, self-unpair, and revoked access"
            )
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func physicalPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw E2EFailure("cannot resolve the physical fixture path") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func handleFixtureCommand() throws -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--fixture-home" else { return false }
        guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--cleanup-identity"),
            arguments[2] == "--profile"
        else { throw E2EFailure("invalid fixture command") }
        let home = URL(fileURLWithPath: arguments[1], isDirectory: true).resolvingSymlinksInPath()
        // Darwin realpath matches the shell's pwd -P; Foundation may preserve
        // /tmp while the shell hashes /private/tmp on macOS.
        let runPath = try physicalPath(home.deletingLastPathComponent().path)
        let artifactRootPath = try physicalPath("/tmp/companion-pairing-e2e")
        let runParentPath = try physicalPath((runPath as NSString).deletingLastPathComponent)
        let suffix = SHA256.hash(data: Data(runPath.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let profile = "development:" + suffix
        guard home.lastPathComponent == "home", (runPath as NSString).lastPathComponent.hasPrefix("run."),
            runParentPath == artifactRootPath, arguments[3] == profile
        else { throw E2EFailure("refusing a non-owned fixture profile") }
        let environment = ProcessInfo.processInfo.environment
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser.path, NSHomeDirectory(),
            environment["HOME"] ?? "", environment["CFFIXED_USER_HOME"] ?? "",
        ]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard paths.allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == home.path }),
            support.resolvingSymlinksInPath().path == home.appending(path: "Library/Application Support", directoryHint: .isDirectory).path
        else { throw E2EFailure("disposable HOME/Foundation path isolation mismatch") }
        if arguments.count == 5 {
            // Match CompanionIdentityStore's profile namespace; this command is
            // restricted to the run-derived disposable profile above.
            let namespace = SHA256.hash(data: Data(profile.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            for query: [String: Any] in [
                [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: "awesoMux Companion " + namespace],
                [
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationTag as String: Data(("com.interactivebuffoonery.awesomux.companion." + namespace).utf8),
                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                ],
            ] {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw E2EFailure("fixture identity cleanup failed: \(status)")
                }
            }
            print("fixture_identity=removed")
        } else {
            print("fixture_home=verified")
        }
        return true
    }

    private struct Invocation {
        let link: String?
        let resultFile: String?
        let profile: String?
        let cleanupResult: String?
        var fixtureSnapshot: String? = nil
    }

    private static func invocation() throws -> Invocation {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--cleanup-result" {
            return Invocation(link: nil, resultFile: nil, profile: nil, cleanupResult: arguments[1])
        }
        if (arguments.count == 6 || (arguments.count == 8 && arguments[6] == "--fixture-snapshot")),
            arguments[0] == "--link-file", arguments[2] == "--result-file", arguments[4] == "--profile"
        {
            return Invocation(
                link: try String(contentsOfFile: arguments[1], encoding: .utf8),
                resultFile: arguments[3],
                profile: arguments[5],
                cleanupResult: nil,
                fixtureSnapshot: arguments.count == 8 ? arguments[7] : nil
            )
        }
        throw E2EFailure(
            "usage: companion-pairing-e2e --link-file path --result-file path --profile development-profile [--fixture-snapshot path] | --cleanup-result path"
        )
    }

    private static func writeCleanupResult(profile: String, connectionID: String, to path: String, expectRevoked: Bool = false) throws {
        try JSONSerialization.data(
            withJSONObject: ["profile": profile, "connectionID": connectionID, "expectRevoked": String(expectRevoked)],
            options: [.sortedKeys]
        ).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @MainActor
    private static func cleanup(resultFile: String) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: resultFile)))
                as? [String: String],
            let profile = object["profile"], let rawID = object["connectionID"], let connectionID = UUID(uuidString: rawID)
        else { throw E2EFailure("cleanup result is invalid") }
        let directoryName: String
        if profile == "development" {
            directoryName = "awesoMux-dev"
        } else if profile.hasPrefix("development:") {
            directoryName = "awesoMux-dev-" + profile.dropFirst("development:".count)
        } else {
            throw E2EFailure("refusing to clean a non-development profile")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = LocalAPIAccessStore(
            profile: profile,
            supportDirectoryURL: appSupport.appending(path: directoryName, directoryHint: .isDirectory)
        )
        guard store.ownsAuthority else { throw E2EFailure("cleanup store is locked") }
        guard store.state.connections.contains(where: { $0.id == connectionID }) else {
            print("cleanup=already_revoked")
            return
        }
        guard store.state.connections.contains(where: { $0.id == connectionID && $0.kind == .companion && $0.label == "E2E iPhone" })
        else { throw E2EFailure("refusing to clean an unexpected or locked connection") }
        try store.revoke(connectionID: connectionID)
        guard object["expectRevoked"] != "true" else { throw E2EFailure("self-revocation was not persisted") }
    }

    private static func verifyWrongSecretIsDenied(link: PairingLink, identity: E2EClientIdentity) async throws {
        let opened = try await CompanionClient.open(link: link, identity: identity)
        let connection = opened.connection
        defer { connection.cancel() }
        let response = try await CompanionClient.exchange(
            [
                "v": 1,
                "op": "pair",
                "secret": Data(repeating: 0, count: 32).base64URL,
                "phoneName": "E2E iPhone",
            ], connection: connection)
        guard response["status"] as? String == "denied" else { throw E2EFailure("wrong secret was not denied") }
        printJSON(label: "wrong_secret", object: response)
    }

    private static func pair(link: PairingLink, identity: E2EClientIdentity) async throws -> String {
        let opened = try await CompanionClient.open(link: link, identity: identity)
        let connection = opened.connection
        defer { connection.cancel() }
        let confirm = try await CompanionClient.exchange(
            [
                "v": 1,
                "op": "pair",
                "secret": link.secret,
                "phoneName": "E2E iPhone",
            ], connection: connection)
        guard confirm["status"] as? String == "confirm" else { throw E2EFailure("pairing was not confirmed") }
        printJSON(label: "pair_confirm", object: confirm)
        print("confirmation_words=\(try confirmationWords(macSPKI: opened.macSPKI, phoneSPKI: identity.spki).joined(separator: " "))")
        let paired = try await CompanionClient.receiveObject(connection: connection)
        guard paired["status"] as? String == "paired", let connectionID = paired["connectionID"] as? String,
            UUID(uuidString: connectionID) != nil
        else { throw E2EFailure("pairing was not allowed") }
        printJSON(label: "paired", object: paired)
        return connectionID
    }

    private static func verifyMacPin(link: PairingLink, identity: E2EClientIdentity) async throws {
        var wrong = link.macFingerprint
        wrong[wrong.startIndex] ^= 0xFF
        let altered = PairingLinkForPin(source: link, fingerprint: wrong)
        do {
            let opened = try await CompanionClient.open(link: altered.link, identity: identity)
            opened.connection.cancel()
            throw E2EFailure("an incorrect Mac SPKI pin was accepted")
        } catch let error as E2EFailure where error.description == "an incorrect Mac SPKI pin was accepted" {
            throw error
        } catch {
            print("wrong_mac_pin=denied")
        }
    }

    private static func call(_ request: [String: Any], link: PairingLink, identity: E2EClientIdentity) async throws -> [String: Any] {
        let connection = try await CompanionClient.open(link: link, identity: identity).connection
        defer { connection.cancel() }
        let response = try await CompanionClient.exchange(request, connection: connection)
        guard let responseID = response["requestID"] as? String, let responseUUID = UUID(uuidString: responseID),
            let requestID = request["requestID"] as? String, let requestUUID = UUID(uuidString: requestID),
            responseUUID == requestUUID
        else {
            throw E2EFailure("response requestID did not match")
        }
        return response
    }

    private static func printJSON(label: String, object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print("\(label)=\(String(decoding: data, as: UTF8.self))")
    }

    private static func confirmationWords(macSPKI: Data, phoneSPKI: Data) throws -> [String] {
        CompanionPairingWords.words(macSPKI: macSPKI, phoneSPKI: phoneSPKI)
    }
}

private struct PairingLinkForPin {
    let link: PairingLink

    init(source: PairingLink, fingerprint: Data) {
        link = PairingLink(
            host: source.host,
            port: source.port,
            macFingerprint: fingerprint,
            secret: source.secret,
            macName: source.macName,
            transport: source.transport,
            advertisedRoutes: source.advertisedRoutes
        )
    }
}

private extension PairingLink {
    init(
        host: NWEndpoint.Host, port: NWEndpoint.Port, macFingerprint: Data, secret: String, macName: String, transport: String,
        advertisedRoutes: [String: String]
    ) {
        self.host = host
        self.port = port
        self.macFingerprint = macFingerprint
        self.secret = secret
        self.macName = macName
        self.transport = transport
        self.advertisedRoutes = advertisedRoutes
    }
}

private extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value.append(String(repeating: "=", count: (4 - value.count % 4) % 4))
        self.init(base64Encoded: value)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
