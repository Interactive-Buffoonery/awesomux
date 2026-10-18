import Foundation

@main struct Check {
 static func main() {
  let start = 1000.0
  let id = UUID().uuidString
  let other = UUID().uuidString
  func evidence(_ sequence: UInt64, at: Double = 1001, client: String? = nil, pid: Int = 42, started: Int = 77, completed: UInt64 = 0, epoch: UInt64 = 1) -> AgentClientStatusEvidence {
   AgentClientStatusEvidence(clientID: client ?? id, sequence: sequence, completedTurns: completed, threadEpoch: epoch, pid: pid, startedAt: started, capturedAt: at)
  }
  var tracker = AgentClientStatusTracker(observationStartedAt: start)
  func accept(_ item: AgentClientStatusEvidence, ready: Bool, now: Double = 1001) -> Bool {
   tracker.accept(item, inputReady: ready, observedPID: 42, observedStartedAt: 77, foregroundMatchesProvider: true, now: now)
  }
  precondition(!accept(evidence(1, at: 999), ready: true), "historical snapshot accepted")
  precondition(accept(evidence(2), ready: true))
  precondition(tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1002))
  precondition(accept(evidence(4), ready: false))
  precondition(!accept(evidence(3), ready: true), "reordered ready accepted")
  precondition(!tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1002))
  precondition(!accept(evidence(5, client: other), ready: true), "client identity rebound on same process")
  precondition(!accept(evidence(5, pid: 43), ready: true), "wrong terminal client accepted")
  precondition(accept(evidence(5, at: 1002), ready: true, now: 1002))
  precondition(!tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1013), "dead reporter never expired")
  precondition(!accept(evidence(6, at: 1020), ready: true, now: 1002), "future snapshot accepted")
  precondition(!tracker.accept(evidence(6, at: 1002), inputReady: true, observedPID: 42, observedStartedAt: 77, foregroundMatchesProvider: false, now: 1002), "unverified executable accepted")
  precondition(accept(evidence(6, at: 1002, completed: 2), ready: true, now: 1002))
  precondition(!accept(evidence(7, at: 1002, completed: 1), ready: true, now: 1002), "completion counter regressed")
  precondition(accept(evidence(7, at: 1002, completed: 2, epoch: 2), ready: true, now: 1002))
  precondition(!accept(evidence(8, at: 1002, completed: 2, epoch: 1), ready: true, now: 1002), "thread epoch regressed")
  let beforeRestart = tracker.current
  tracker.invalidateObservation(now: 1003)
  precondition(!tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1003), "watch restart retained positive readiness")
  precondition(tracker.current == beforeRestart, "watch restart lost authority or ordering")
  precondition(!accept(evidence(8, at: 1002, completed: 2, epoch: 2), ready: true, now: 1003), "pre-restart snapshot restored readiness")
  precondition(!accept(evidence(7, at: 1003, completed: 2, epoch: 2), ready: true, now: 1003), "restart reset sequence watermark")
  precondition(!accept(evidence(8, at: 1003, completed: 2, epoch: 2), ready: true, now: 1003), "equal restart timestamp restored readiness")
  precondition(accept(evidence(8, at: 1003.01, completed: 2, epoch: 2), ready: true, now: 1003.01))
  // A process replacement between event acceptance and stamping must not inherit readiness.
  precondition(!tracker.isReady(observedPID: 43, observedStartedAt: 88, now: 1003.02), "A evidence authorized B stamp")
  precondition(!tracker.isReady(observedPID: 42, observedStartedAt: 88, now: 1003.02), "reused PID inherited readiness")
  precondition(tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1003.02), "A failed to recover with its own stamp")
  precondition(tracker.accept(evidence(1, at: 1004, client: other, pid: 43, started: 88), inputReady: true, observedPID: 43, observedStartedAt: 88, foregroundMatchesProvider: true, now: 1004))
  precondition(!tracker.isReady(observedPID: 42, observedStartedAt: 77, now: 1004), "B evidence authorized old A stamp")
  precondition(tracker.isReady(observedPID: 43, observedStartedAt: 88, now: 1004), "B failed to recover with fresh matching evidence")
  print("PASS: replay, ordering, identity binding, terminal isolation, expiry, future time, executable gate, observation restart, A/B stamp rejection and recovery")
 }
}
