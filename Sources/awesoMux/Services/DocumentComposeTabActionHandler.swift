import AwesoMuxCore
import Foundation
import Observation

@MainActor
@Observable
final class DocumentComposeTabActionHandler {
    private(set) var noticeID: UUID?

    func perform(
        _ action: () -> Void,
        announce: (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        switch DocumentComposeGuard.tabActionDecision() {
        case .allowed:
            noticeID = nil
            action()
        case .blocked(let message):
            let shouldAnnounce = noticeID == nil
            let newNoticeID = UUID()
            noticeID = newNoticeID
            if shouldAnnounce {
                announce(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.noticeID == newNoticeID {
                    self?.noticeID = nil
                }
            }
        }
    }
}
