import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

/// Captured identity, not a connection grant. Observations only invalidate an
/// unmanaged attempt; they never supply its independently confirmed target.
struct RemoteMarkdownReadOrigin: Equatable, Sendable {
    let sessionID: TerminalSession.ID
    let documentID: DocumentPane.ID?
    let documentIdentity: ResourceIdentity?
    let documentReadPolicy: RemoteDocumentReadPolicy?
    let associatedTerminalPaneID: TerminalPane.ID?
    let paneID: TerminalPane.ID?
    let terminalSessionID: TerminalSessionID?
    let executionPlan: PaneExecutionPlan?
    let connectionHealth: RemoteConnectionHealth?
    let observedRemoteHost: String?
    let observedSSHTarget: String?
    let pendingSSHTarget: String?
    let observedPendingSSHProcess: Bool?

    init(sessionID: TerminalSession.ID, pane: TerminalPane?, document: DocumentPane? = nil) {
        precondition(pane != nil || document != nil)
        self.sessionID = sessionID
        documentID = document?.id
        documentIdentity = document?.remoteResourceIdentity
        documentReadPolicy = document?.remoteReadPolicy
        associatedTerminalPaneID = document?.associatedTerminalPaneID
        paneID = pane?.id
        terminalSessionID = pane?.terminalSessionID
        executionPlan = pane?.executionPlan
        connectionHealth = pane?.remoteConnectionHealth
        let observesUnmanaged = pane?.executionPlan == .local
        observedRemoteHost = observesUnmanaged ? pane?.remoteHost : nil
        observedSSHTarget = observesUnmanaged ? pane?.remoteSSHTarget : nil
        pendingSSHTarget = observesUnmanaged ? pane?.pendingRemoteSSHTarget : nil
        observedPendingSSHProcess = observesUnmanaged ? pane?.hasObservedPendingRemoteSSHProcess : nil
    }
}

struct RemoteMarkdownReadAttempt: Equatable, Sendable {
    let origin: RemoteMarkdownReadOrigin
    let target: RemoteTarget
    let readPolicy: RemoteDocumentReadPolicy
    /// The explicitly chosen base, never an inferred current working directory.
    let chosenBaseDirectory: String?
    fileprivate let token: UUID

    fileprivate init(
        origin: RemoteMarkdownReadOrigin,
        target: RemoteTarget,
        readPolicy: RemoteDocumentReadPolicy,
        chosenBaseDirectory: String?
    ) {
        self.origin = origin
        self.target = target
        self.readPolicy = readPolicy
        self.chosenBaseDirectory = chosenBaseDirectory
        token = UUID()
    }
}

/// One operation per authorization. No reliable unmanaged SSH lifecycle epoch
/// exists, so every later read must return to explicit confirmation.
@MainActor
final class RemoteMarkdownReadAuthorization {
    private enum Stage {
        case authorized
        case fetching
    }

    private static let maximumAttempts = 512
    private var attempts: [UUID: (attempt: RemoteMarkdownReadAttempt, stage: Stage)] = [:]
    private var registrationOrder: [UUID] = []

    func authorizeDeclared(origin: RemoteMarkdownReadOrigin, chosenBaseDirectory: String? = nil) -> RemoteMarkdownReadAttempt? {
        guard origin.documentReadPolicy != .confirmationRequired else { return nil }
        let target: RemoteTarget
        if origin.documentID != nil {
            // Managed snapshots retain their saved authority after terminal
            // closure; a sibling pane must never choose their read target.
            guard let identity = origin.documentIdentity,
                identity.isSupportedRemoteMarkdownSnapshot,
                let savedTarget = identity.remoteTarget
            else {
                return nil
            }
            target = savedTarget
        } else {
            guard let declaredTarget = origin.executionPlan?.remoteTarget else { return nil }
            target = declaredTarget
        }
        return register(origin: origin, target: target, policy: .declaredIdentity, chosenBaseDirectory: chosenBaseDirectory)
    }

    /// Call only after the user approves this exact independent file-read target.
    /// Confirmation never edits the terminal's execution plan or persisted target.
    func confirmOneOperation(
        origin: RemoteMarkdownReadOrigin,
        target: RemoteTarget,
        chosenBaseDirectory: String? = nil
    ) -> RemoteMarkdownReadAttempt? {
        if origin.documentID != nil {
            guard let identity = origin.documentIdentity,
                identity.isSupportedRemoteMarkdownSnapshot,
                identity.remoteTarget == target
            else {
                return nil
            }
        }
        return register(
            origin: origin,
            target: target,
            policy: .confirmationRequired,
            chosenBaseDirectory: chosenBaseDirectory
        )
    }

    func consumeBeforeFetch(_ attempt: RemoteMarkdownReadAttempt, currentOrigin: RemoteMarkdownReadOrigin?) -> Bool {
        guard let entry = attempts[attempt.token], entry.attempt == attempt,
            case .authorized = entry.stage,
            currentOrigin == attempt.origin
        else {
            discard(attempt)
            return false
        }
        attempts[attempt.token] = (attempt, .fetching)
        return true
    }

    func validateBeforeTransport(_ attempt: RemoteMarkdownReadAttempt, currentOrigin: RemoteMarkdownReadOrigin?) -> Bool {
        guard let entry = attempts[attempt.token], entry.attempt == attempt,
            case .fetching = entry.stage, currentOrigin == attempt.origin
        else {
            discard(attempt)
            return false
        }
        return true
    }

    /// Call before applying the result, including after a cache/coalesced fetch.
    func validateAfterFetch(_ attempt: RemoteMarkdownReadAttempt, currentOrigin: RemoteMarkdownReadOrigin?) -> Bool {
        let entry = attempts[attempt.token]
        discard(attempt)
        guard let entry, entry.attempt == attempt, case .fetching = entry.stage else { return false }
        return currentOrigin == attempt.origin
    }

    func discard(_ attempt: RemoteMarkdownReadAttempt) {
        attempts.removeValue(forKey: attempt.token)
        registrationOrder.removeAll { $0 == attempt.token }
    }

    private func register(
        origin: RemoteMarkdownReadOrigin,
        target: RemoteTarget,
        policy: RemoteDocumentReadPolicy,
        chosenBaseDirectory: String?
    ) -> RemoteMarkdownReadAttempt {
        let attempt = RemoteMarkdownReadAttempt(
            origin: origin,
            target: target,
            readPolicy: policy,
            chosenBaseDirectory: chosenBaseDirectory
        )
        // Abandoned fetching records share the bound. Eviction revokes the
        // token, so even an already-started read can no longer apply a result.
        if registrationOrder.count >= Self.maximumAttempts {
            attempts.removeValue(forKey: registrationOrder.removeFirst())
        }
        attempts[attempt.token] = (attempt, .authorized)
        registrationOrder.append(attempt.token)
        return attempt
    }
}
