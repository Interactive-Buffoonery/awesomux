import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct RemoteTargetTests {
    @Test func parsesUserAndHost() {
        let target = RemoteTarget(parsing: "ed@mac-mini.local")
        #expect(target == RemoteTarget(user: "ed", host: "mac-mini.local")!)
        #expect(target?.sshDestination == "ed@mac-mini.local")
    }

    @Test func parsesHostOnlyWithEmptyUser() {
        let target = RemoteTarget(parsing: "mac-mini")
        #expect(target == RemoteTarget(user: "", host: "mac-mini")!)
        #expect(target?.sshDestination == "mac-mini")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(RemoteTarget(parsing: "  ed@host  ") == RemoteTarget(user: "ed", host: "host")!)
    }

    @Test func rejectsEmptyOrHostlessInput() {
        #expect(RemoteTarget(user: "ed", host: "") == nil)
        #expect(RemoteTarget(user: "ed", host: "   ") == nil)
        #expect(RemoteTarget(parsing: "") == nil)
        #expect(RemoteTarget(parsing: "   ") == nil)
        #expect(RemoteTarget(parsing: "ed@") == nil)
        #expect(RemoteTarget(parsing: "@host") == RemoteTarget(user: "", host: "host")!)
    }

    @Test func roundTripsThroughCodable() throws {
        let target = RemoteTarget(user: "ed", host: "box")!
        let data = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(RemoteTarget.self, from: data) == target)
    }
}
