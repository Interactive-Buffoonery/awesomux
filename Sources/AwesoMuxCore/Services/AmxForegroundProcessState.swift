/// Result of comparing authenticated foreground evidence with an executable.
/// `unknown` is deliberately distinct from negative evidence so callers can
/// fail closed when the status feed is missing or degraded.
public enum AmxForegroundExecutableMatch: Equatable, Sendable {
    case matching
    case notMatching
    case unknown
}

/// One validated foreground-process publication from zmx's authenticated,
/// per-attach status file.
public struct AmxForegroundProcessPublication: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case foreground(processGroupID: Int, executable: String)
        case noForeground
        case unavailable
        case malformed
        case stale
    }

    public let daemon: AmxDaemonIncarnation
    public let transitionSequence: UInt64
    public let sampleSequence: UInt64
    public let state: State

    public init(
        daemon: AmxDaemonIncarnation,
        transitionSequence: UInt64,
        sampleSequence: UInt64,
        state: State
    ) {
        self.daemon = daemon
        self.transitionSequence = transitionSequence
        self.sampleSequence = sampleSequence
        self.state = state
    }
}

/// Runtime-only reducer for one authenticated attach lifecycle.
///
/// The daemon identity is established by `attached`; publications from another
/// identity, replayed/regressed samples, explicit degradation, or a transition
/// whose meaning changes without a sequence advance all clear usable evidence.
/// Watermarks survive rejected samples so a replay cannot become current after
/// it invalidates the prior observation.
public struct AmxForegroundProcessState: Equatable, Sendable {
    private var daemon: AmxDaemonIncarnation?
    private var lastTransitionSequence: UInt64 = 0
    private var lastSampleSequence: UInt64 = 0
    private var lastState: AmxForegroundProcessPublication.State?
    private var current: AmxForegroundProcessPublication?

    public init() {}

    public mutating func beginAttach(to daemon: AmxDaemonIncarnation) {
        self.daemon = daemon
        lastTransitionSequence = 0
        lastSampleSequence = 0
        lastState = nil
        current = nil
    }

    public mutating func consume(_ publication: AmxForegroundProcessPublication) {
        guard let attachedDaemon = daemon,
            publication.daemon.pid == attachedDaemon.pid,
            publication.daemon.createdAt == attachedDaemon.createdAt,
            publication.daemon.incarnation > 0,
            attachedDaemon.incarnation == 0 || publication.daemon == attachedDaemon
        else {
            invalidate()
            return
        }
        if attachedDaemon.incarnation == 0 {
            daemon = publication.daemon
        }

        switch publication.state {
        case .malformed, .stale:
            lastTransitionSequence = max(lastTransitionSequence, publication.transitionSequence)
            lastSampleSequence = max(lastSampleSequence, publication.sampleSequence)
            invalidate()
            return
        case .foreground, .noForeground, .unavailable:
            break
        }

        guard publication.transitionSequence > 0,
            publication.sampleSequence > lastSampleSequence,
            publication.transitionSequence >= lastTransitionSequence,
            publication.transitionSequence <= publication.sampleSequence
        else {
            invalidate()
            return
        }

        if publication.transitionSequence == lastTransitionSequence,
            let lastState,
            lastState != publication.state
        {
            invalidate()
            lastSampleSequence = publication.sampleSequence
            return
        }

        if publication.transitionSequence > lastTransitionSequence {
            lastState = publication.state
        }
        lastTransitionSequence = publication.transitionSequence
        lastSampleSequence = publication.sampleSequence
        current = publication
    }

    public mutating func invalidate() {
        current = nil
    }

    public mutating func reset() {
        self = Self()
    }

    public func match(executable: String) -> AmxForegroundExecutableMatch {
        guard let current else { return .unknown }
        switch current.state {
        case let .foreground(_, observed):
            return observed == executable ? .matching : .notMatching
        case .noForeground:
            return .notMatching
        case .unavailable, .malformed, .stale:
            return .unknown
        }
    }
}
