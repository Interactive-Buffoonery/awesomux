import AwesoMuxCore
import XCTest

final class WorkspaceNotificationRoutingTests: XCTestCase {
    func testDecodesSessionIDFromUserInfo() {
        let sessionID = UUID()
        let userInfo: [AnyHashable: Any] = [
            WorkspaceNotificationUserInfoKey.sessionID: sessionID.uuidString
        ]

        XCTAssertEqual(
            WorkspaceNotificationRouting.sessionID(fromUserInfo: userInfo),
            sessionID
        )
    }

    func testReturnsNilForMissingKey() {
        XCTAssertNil(WorkspaceNotificationRouting.sessionID(fromUserInfo: [:]))
    }

    func testReturnsNilForMalformedUUIDString() {
        let userInfo: [AnyHashable: Any] = [
            WorkspaceNotificationUserInfoKey.sessionID: "not-a-uuid"
        ]

        XCTAssertNil(WorkspaceNotificationRouting.sessionID(fromUserInfo: userInfo))
    }

    func testReturnsNilForWrongValueType() {
        let userInfo: [AnyHashable: Any] = [
            WorkspaceNotificationUserInfoKey.sessionID: 42
        ]

        XCTAssertNil(WorkspaceNotificationRouting.sessionID(fromUserInfo: userInfo))
    }
}
