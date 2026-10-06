#!/usr/bin/env python3
"""Verify the actual read authorizer against the actual core model product."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', default=str(root / '.build/verification/remote-markdown-authorization.log'))
args = parser.parse_args()

proof = r'''
import AwesoMuxCore
import Foundation
import Testing

@MainActor
@Suite("Actual remote Markdown read authorization", .serialized)
struct AuthorizationProof {
    let target = RemoteTarget(parsing: "proof-alias")!
    let otherTarget = RemoteTarget(parsing: "other-proof-alias")!
    let sessionID = UUID()

    func pane(managed: Bool = true) -> TerminalPane {
        TerminalPane(title: "proof", workingDirectory: "/tmp", executionPlan: managed ? .ssh(SSHExecution(target: target)) : .local)
    }
    func origin(_ pane: TerminalPane) -> RemoteMarkdownReadOrigin {
        RemoteMarkdownReadOrigin(sessionID: sessionID, pane: pane)
    }
    func document(policy: RemoteDocumentReadPolicy = .declaredIdentity) -> DocumentPane {
        DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/proof-cache.md"), title: "proof.md",
            remoteResourceIdentity: ResourceIdentity(location: .remote(target), path: ResourcePath(rawValue: "/repo/proof.md")), remoteReadPolicy: policy)
    }
    func count(_ service: RemoteMarkdownReadAuthorization, field: String) -> Int {
        guard let value = Mirror(reflecting: service).children.first(where: { $0.label == field })?.value else { return 0 }
        return Mirror(reflecting: value).children.count
    }

    @Test func oneUseAndReplayFailClosed() throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        let first = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(first, currentOrigin: captured))
        #expect(service.validateAfterFetch(first, currentOrigin: captured))
        #expect(!service.consumeBeforeFetch(first, currentOrigin: captured))
        #expect(!service.validateAfterFetch(first, currentOrigin: captured))
        let replayed = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(replayed, currentOrigin: captured))
        #expect(!service.consumeBeforeFetch(replayed, currentOrigin: captured))
        #expect(!service.validateAfterFetch(replayed, currentOrigin: captured))
        let premature = try #require(service.authorizeDeclared(origin: captured))
        #expect(!service.validateAfterFetch(premature, currentOrigin: captured))
        #expect(!service.consumeBeforeFetch(premature, currentOrigin: captured))
    }

    @Test(arguments: [false, true]) func missingOriginFailsClosed(afterConsume: Bool) throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        let attempt = try #require(service.authorizeDeclared(origin: captured))
        if afterConsume {
            #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured))
            #expect(!service.validateAfterFetch(attempt, currentOrigin: nil))
        } else {
            #expect(!service.consumeBeforeFetch(attempt, currentOrigin: nil))
        }
        #expect(!service.consumeBeforeFetch(attempt, currentOrigin: captured))
        #expect(!service.validateAfterFetch(attempt, currentOrigin: captured))
    }

    @Test(arguments: [false, true]) func changedOriginFailsClosed(afterConsume: Bool) throws {
        let service = RemoteMarkdownReadAuthorization(), originalPane = pane()
        let captured = origin(originalPane)
        var changedPane = originalPane
        changedPane.executionPlan = .ssh(SSHExecution(target: otherTarget))
        let attempt = try #require(service.authorizeDeclared(origin: captured))
        if afterConsume {
            #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured))
            #expect(!service.validateAfterFetch(attempt, currentOrigin: origin(changedPane)))
        } else {
            #expect(!service.consumeBeforeFetch(attempt, currentOrigin: origin(changedPane)))
        }
        #expect(!service.consumeBeforeFetch(attempt, currentOrigin: captured))
    }

    @Test func observationsNeverGrantAndChangesInvalidate() throws {
        let service = RemoteMarkdownReadAuthorization()
        var unmanaged = pane(managed: false)
        unmanaged.remoteHost = "observed.example"
        unmanaged.remoteSSHTarget = "observed-alias"
        let captured = origin(unmanaged)
        #expect(service.authorizeDeclared(origin: captured) == nil)
        let attempt = try #require(service.confirmOneOperation(origin: captured, target: otherTarget, chosenBaseDirectory: "/chosen"))
        #expect(attempt.target == otherTarget && attempt.chosenBaseDirectory == "/chosen")
        #expect(attempt.readPolicy == .confirmationRequired)
        #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured))
        unmanaged.remoteSSHTarget = "changed-alias"
        #expect(!service.validateAfterFetch(attempt, currentOrigin: origin(unmanaged)))
        #expect(unmanaged.executionPlan == .local)
    }

    @Test func savedTargetAndRestrictiveConfirmation() throws {
        let service = RemoteMarkdownReadAuthorization()
        let sibling = TerminalPane(title: "other", workingDirectory: "/tmp", executionPlan: .ssh(SSHExecution(target: otherTarget)))
        let saved = document()
        let declared = try #require(service.authorizeDeclared(origin: RemoteMarkdownReadOrigin(sessionID: sessionID, pane: sibling, document: saved)))
        #expect(declared.target == target && declared.readPolicy == .declaredIdentity)
        service.discard(declared)
        let restrictive = document(policy: .confirmationRequired)
        let captured = RemoteMarkdownReadOrigin(sessionID: sessionID, pane: nil, document: restrictive)
        #expect(service.authorizeDeclared(origin: captured) == nil)
        #expect(service.confirmOneOperation(origin: captured, target: otherTarget) == nil)
        let confirmed = try #require(service.confirmOneOperation(origin: captured, target: target))
        #expect(service.consumeBeforeFetch(confirmed, currentOrigin: captured))
        #expect(service.validateAfterFetch(confirmed, currentOrigin: captured))
        let orphan = RemoteMarkdownReadOrigin(sessionID: sessionID, pane: nil, document: saved)
        #expect(service.authorizeDeclared(origin: orphan)?.target == target)
    }

    @Test func policyAndAssociationChangesRejectDisplay() throws {
        let service = RemoteMarkdownReadAuthorization(), original = document()
        let captured = RemoteMarkdownReadOrigin(sessionID: sessionID, pane: nil, document: original)
        let attempt = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured))
        var changed = original
        changed.associatedTerminalPaneID = UUID()
        #expect(!service.validateAfterFetch(attempt, currentOrigin: RemoteMarkdownReadOrigin(sessionID: sessionID, pane: nil, document: changed)))
        let next = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(next, currentOrigin: captured))
        changed = DocumentPane(id: original.id, fileURL: original.fileURL, title: original.title,
            remoteResourceIdentity: original.remoteResourceIdentity, remoteReadPolicy: .confirmationRequired)
        #expect(!service.validateAfterFetch(next, currentOrigin: RemoteMarkdownReadOrigin(sessionID: sessionID, pane: nil, document: changed)))
    }

    @Test(arguments: [false, true]) func discardRetiresEveryStage(fetching: Bool) throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        let attempt = try #require(service.authorizeDeclared(origin: captured))
        if fetching { #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured)) }
        service.discard(attempt)
        service.discard(attempt)
        #expect(!service.consumeBeforeFetch(attempt, currentOrigin: captured))
        #expect(!service.validateAfterFetch(attempt, currentOrigin: captured))
        #expect(count(service, field: "attempts") == 0)
        #expect(count(service, field: "registrationOrder") == 0)
    }

    @Test(arguments: [false, true]) func abandonedRecordsStayBounded(fetching: Bool) throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        var records: [RemoteMarkdownReadAttempt] = []
        for _ in 0..<2048 {
            let attempt = try #require(service.authorizeDeclared(origin: captured))
            if fetching { #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured)) }
            records.append(attempt)
        }
        #expect(count(service, field: "attempts") == 512)
        #expect(count(service, field: "registrationOrder") == 512)
        // FIFO boundary: the first 1536 are evicted, the newest 512 survive.
        if fetching {
            #expect(!service.validateAfterFetch(records[1535], currentOrigin: captured))
            #expect(service.validateAfterFetch(records[1536], currentOrigin: captured))
        } else {
            #expect(!service.consumeBeforeFetch(records[1535], currentOrigin: captured))
            #expect(service.consumeBeforeFetch(records[1536], currentOrigin: captured))
            #expect(service.validateAfterFetch(records[1536], currentOrigin: captured))
        }
        for record in records { service.discard(record) }
        #expect(count(service, field: "attempts") == 0)
        #expect(count(service, field: "registrationOrder") == 0)
        let fresh = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(fresh, currentOrigin: captured))
        #expect(service.validateAfterFetch(fresh, currentOrigin: captured))
    }

    @Test func activeFetchingEvictionFailsClosed() throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        let active = try #require(service.authorizeDeclared(origin: captured))
        #expect(service.consumeBeforeFetch(active, currentOrigin: captured))
        for _ in 0..<512 { _ = service.authorizeDeclared(origin: captured) }
        #expect(!service.validateAfterFetch(active, currentOrigin: captured))
        #expect(!service.consumeBeforeFetch(active, currentOrigin: captured))
        #expect(count(service, field: "attempts") == 512)
    }

    @Test func normalCompletionDoesNotAccumulateOrdering() throws {
        let service = RemoteMarkdownReadAuthorization(), captured = origin(pane())
        for _ in 0..<2048 {
            let attempt = try #require(service.authorizeDeclared(origin: captured))
            #expect(service.consumeBeforeFetch(attempt, currentOrigin: captured))
            #expect(service.validateAfterFetch(attempt, currentOrigin: captured))
        }
        #expect(count(service, field: "attempts") == 0)
        #expect(count(service, field: "registrationOrder") == 0)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='awesomux-authorization-proof-') as directory:
    package = Path(directory)
    tests = package / 'Tests/AuthorizationProof'
    tests.mkdir(parents=True)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "AuthorizationProof", platforms: [.macOS(.v15)],
    dependencies: [.package(path: ROOT)],
    targets: [.testTarget(name: "AuthorizationProof", dependencies: [.product(name: "AwesoMuxCore", package: IDENTITY)])])
'''.replace('ROOT', json.dumps(str(root))).replace('IDENTITY', json.dumps(root.name)))
    source = root / 'Sources/awesoMux/Services/RemoteMarkdownReadAuthorization.swift'
    (tests / source.name).write_text(source.read_text())
    (tests / 'AuthorizationProof.swift').write_text(proof)
    result = subprocess.run(['swift', 'test', '--package-path', str(package)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    report = 'Actual service: RemoteMarkdownReadAuthorization.swift\n' + f'Service SHA256: {hashlib.sha256(source.read_bytes()).hexdigest()}\n' + 'Actual models: AwesoMuxCore product from repository dependency\n' + result.stdout
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(report)
    print(report)
    print(f'Proof artifact: {output}')
    raise SystemExit(result.returncode)
