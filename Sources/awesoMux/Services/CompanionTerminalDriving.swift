import AwesoMuxCompanionProtocol
import Foundation
import Observation

/// Maps daemon attachment IDs to paired streams, never guesses leadership from input.
@MainActor
@Observable
final class CompanionTerminalDriving {
    static let shared = CompanionTerminalDriving()

    struct Device {
        let sessionName: String
        let attachmentID: UInt64
        let streamID: UUID
        let name: String
        let disconnect: () -> Void
    }

    private(set) var devices: [UUID: [UUID: Device]] = [:]
    private var departedAttachments: [UUID: Set<UInt64>] = [:]
    private(set) var monitoredSessions: [UUID: String] = [:]
    private(set) var revisions: [UUID: UInt64] = [:]

    func register(
        paneID: UUID, sessionName: String, attachmentID: UInt64, streamID: UUID, deviceName: String, disconnect: @escaping () -> Void
    ) {
        monitoredSessions[paneID] = sessionName
        devices[paneID, default: [:]][streamID] = Device(
            sessionName: sessionName, attachmentID: attachmentID, streamID: streamID, name: deviceName, disconnect: disconnect)
        revisions[paneID, default: 0] += 1
    }

    func remove(streamID: UUID, paneID: UUID) {
        guard let departed = devices[paneID]?.removeValue(forKey: streamID) else { return }
        departedAttachments[paneID, default: []].insert(departed.attachmentID)
        if devices[paneID]?.isEmpty == true { devices.removeValue(forKey: paneID) }
        revisions[paneID, default: 0] += 1
    }

    func didObserve(paneID: UUID, sessionName: String, leader: UInt64) {
        // Socket cancellation precedes daemon-side detach. A fresh observer
        // can still see that departed phone lead until Authority catches up.
        guard leader != 0, devices[paneID] == nil, monitoredSessions[paneID] == sessionName,
            departedAttachments[paneID]?.contains(leader) != true
        else { return }
        departedAttachments.removeValue(forKey: paneID)
        monitoredSessions.removeValue(forKey: paneID)
        revisions.removeValue(forKey: paneID)
    }

    func device(paneID: UUID, sessionName: String, leader: UInt64) -> Device? {
        devices[paneID]?.values.first { $0.sessionName == sessionName && $0.attachmentID == leader }
    }
}
