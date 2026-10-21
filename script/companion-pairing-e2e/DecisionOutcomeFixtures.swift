import Foundation

// Keep the network assertion and its ordering regression on the same path.
func verifyRefreshedDecisionList(_ response: [String: Any], live: [String: Any], connectionID: String) throws {
    guard let liveInvocation = UUID(uuidString: live["invocationID"] as? String ?? ""),
        (response["pendingDecisions"] as? [[String: Any]])?.count == 1,
        let current = (response["decisionOutcomes"] as? [[String: Any]])?.first(where: {
            let identity = $0["identity"] as? [String: Any]
            return UUID(uuidString: identity?["invocationID"] as? String ?? "") == liveInvocation
        }),
        let source = current["source"] as? [String: Any],
        UUID(uuidString: source["deviceID"] as? String ?? "") == UUID(uuidString: connectionID),
        source["name"] as? String == "E2E iPhone"
    else { throw E2EFailure("fresh list lost the queued request or winning device source") }
}

// Failure mode: a retained expired outcome can precede the live answered outcome.
// Both orderings must pass, while missing/wrong winning source or pending state fail.
func verifyDecisionOutcomeOrdering() throws {
    let phone = UUID().uuidString
    let live: [String: Any] = ["invocationID": UUID().uuidString]
    let answered: [String: Any] = ["identity": live, "source": ["deviceID": phone, "name": "E2E iPhone"]]
    let expired: [String: Any] = ["identity": ["invocationID": UUID().uuidString], "state": "expired"]
    for outcomes in [[expired, answered], [answered, expired]] {
        try verifyRefreshedDecisionList(
            ["pendingDecisions": [["queued": true]], "decisionOutcomes": outcomes], live: live, connectionID: phone)
    }
    for response: [String: Any] in [
        ["pendingDecisions": [["queued": true]], "decisionOutcomes": [expired]],
        ["pendingDecisions": [], "decisionOutcomes": [answered]],
        [
            "pendingDecisions": [["queued": true]],
            "decisionOutcomes": [["identity": live, "source": ["deviceID": UUID().uuidString, "name": "E2E iPhone"]]],
        ],
        [
            "pendingDecisions": [["queued": true]],
            "decisionOutcomes": [["identity": live, "source": ["deviceID": phone, "name": "Other phone"]]],
        ],
    ] {
        do {
            try verifyRefreshedDecisionList(response, live: live, connectionID: phone)
        } catch { continue }
        throw E2EFailure("decision ordering regression accepted missing pending state or wrong winning source")
    }
}
