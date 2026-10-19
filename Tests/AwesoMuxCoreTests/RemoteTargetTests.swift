import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct RemoteTargetTests {
    @Test(arguments: [
        ("ed@mac-mini.local", "ed", "mac-mini.local", "ed@mac-mini.local" as String?),
        ("mac-mini", "", "mac-mini", "mac-mini"),
        ("  ed@host  ", "ed", "host", "ed@host"),
        ("", "ed", "", nil), ("   ", "ed", "   ", nil),
        ("ed@", "ed", "", nil), ("@host", "", "host", "host"),
    ])
    func parsesDestination(input: String, user: String, host: String, destination: String?) {
        let target = RemoteTarget(parsing: input)
        #expect(target == RemoteTarget(user: user, host: host))
        #expect(target?.sshDestination == destination)
    }

    @Test func rejectsUnsafeRoutingScalarsAndDashLeadingDestinations() {
        #expect(RemoteTarget(user: "ed\u{202E}", host: "box") == nil)
        #expect(RemoteTarget(user: "ed", host: "bo\u{200B}x") == nil)
        #expect(RemoteTarget(user: "", host: "-oProxyCommand=bad") == nil)
        #expect(RemoteTarget(parsing: "-oProxyCommand=bad") == nil)
        #expect(RemoteTarget(parsing: "ed@-host") == RemoteTarget(user: "ed", host: "-host"))
    }

    @Test(arguments: [
        (#"{"user":"ed","host":"bo\u202ex"}"#, nil as String?),
        (#"{"user":"","host":"-oProxyCommand=bad"}"#, nil),
        (#"{"user":"ed","host":"-host"}"#, "-host"),
    ])
    func decodesValidatedDestination(json: String, host: String?) throws {
        let data = Data(json.utf8)
        if let host {
            #expect(try JSONDecoder().decode(RemoteTarget.self, from: data) == RemoteTarget(user: "ed", host: host)!)
        } else {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(RemoteTarget.self, from: data)
            }
        }
    }
}
