import Foundation
import Observation

@MainActor
@Observable
final class RemoteAdditionalSSHFeaturesSheetPresenter {
    enum Action: Equatable, Sendable {
        case install
        case update
    }

    struct Request: Identifiable, Equatable, Sendable {
        let id: UUID
        let action: Action
        let destination: String
        let platform: String
        let installPath: String
    }

    static let shared = RemoteAdditionalSSHFeaturesSheetPresenter()

    var request: Request? {
        didSet {
            if oldValue != nil, request == nil, pendingDecision == nil {
                pendingDecision = false
            }
        }
    }

    private var pendingDecision: Bool?
    private var completion: ((Bool) -> Void)?

    func present(
        action: Action,
        destination: String,
        platform: String,
        installPath: String
    ) async -> Bool {
        guard request == nil, completion == nil else {
            return false
        }

        return await withCheckedContinuation { continuation in
            completion = { continuation.resume(returning: $0) }
            request = Request(
                id: UUID(),
                action: action,
                destination: destination,
                platform: platform,
                installPath: installPath
            )
        }
    }

    func choose(requestID: UUID, install: Bool) {
        guard request?.id == requestID else { return }
        pendingDecision = install
        request = nil
    }

    func presentationDidDismiss() {
        guard let completion else { return }
        let decision = pendingDecision ?? false
        pendingDecision = nil
        self.completion = nil
        completion(decision)
    }
}
