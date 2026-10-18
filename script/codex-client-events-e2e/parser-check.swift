import AwesoMuxCore
import Foundation
let evidence: [String: Any] = ["clientID": UUID().uuidString, "sequence": 1, "completedTurns": 0, "threadEpoch": 1, "pid": 1, "startedAt": 1, "capturedAt": 1.25]
func parse(_ value: Any, source: String = "codex") -> AgentRuntimeEvent? {
    AgentRuntimeEvent.parse(data: try! JSONSerialization.data(withJSONObject: ["v": 1, "source": source, "execution": "waiting", "clientStatus": value]))
}
assert(parse(evidence)?.clientStatus?.isValid == true)
for value: Any in [NSNull(), "bad", 1, [:], ["clientID": "bad", "sequence": 1, "pid": 1, "startedAt": 1, "capturedAt": 1]] {
    assert(parse(value) == nil)
}
assert(parse(evidence, source: "claude-code") == nil)
assert(AgentRuntimeEvent.parse(line: "{\"v\":1,\"source\":\"codex\",\"execution\":\"waiting\"}")?.assertsWaitingExecutionState == true)
print("PASS: valid evidence roundtrip; malformed/null/wrong-source evidence drops whole event; legacy stays compatible")

let unavailable = try! JSONSerialization.data(withJSONObject: ["v": 1, "source": "codex", "phase": "notification", "clientStatus": evidence])
assert(AgentRuntimeEvent.parse(data: unavailable)?.clientStatus?.isValid == true)

var missingCounter = evidence
missingCounter.removeValue(forKey: "completedTurns")
assert(parse(missingCounter) == nil)

var missingEpoch = evidence
missingEpoch.removeValue(forKey: "threadEpoch")
assert(parse(missingEpoch) == nil)
var zeroEpoch = evidence
zeroEpoch["threadEpoch"] = 0
assert(parse(zeroEpoch) == nil)
