import Foundation
import os

/// Audited constants for the anonymous PostHog project. The project token is a
/// public client-side ingestion key, not a secret.
enum AnalyticsProviderConfiguration {
    static let posthogCaptureEndpoint = "https://us.i.posthog.com/i/v0/e/"
    static let posthogProjectToken = "phc_zqGZJCNq3NcZ8gVvQnWfvy7vEeVwun3VA79N9o5rHmiy"
}

/// Small transport over PostHog's documented public Capture API. It has no
/// provider-owned identity, persistence, retry queue, remote config, or
/// automatic capture surface.
@MainActor
final class PostHogCaptureProvider: AnalyticsDeliveryProvider {
    static let maximumInFlightRequests = 4
    private static let timestampFormatter = ISO8601DateFormatter()

    private let projectToken: String
    private let endpoint: URL
    private let sessionConfiguration: URLSessionConfiguration
    private var inFlightTasks: [Int: URLSessionDataTask] = [:]
    private lazy var sessionDelegate = PostHogCaptureSessionDelegate { [weak self] taskID, statusCode, error in
        Task { @MainActor [weak self] in
            self?.requestDidComplete(taskID: taskID, statusCode: statusCode, error: error)
        }
    }
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: sessionDelegate,
        delegateQueue: nil
    )
    private let logger = Logger(subsystem: "awesomux.analytics", category: "posthog-capture")

    var inFlightRequestCount: Int { inFlightTasks.count }

    init(
        projectToken: String = AnalyticsProviderConfiguration.posthogProjectToken,
        endpoint: URL? = URL(string: AnalyticsProviderConfiguration.posthogCaptureEndpoint),
        sessionConfiguration: URLSessionConfiguration = PostHogCaptureProvider.makeSessionConfiguration()
    ) {
        self.projectToken = projectToken
        self.endpoint = endpoint ?? URL(fileURLWithPath: "/invalid-posthog-endpoint")
        self.sessionConfiguration = sessionConfiguration
    }

    func capture(
        _ event: SanitizedAnalyticsEvent,
        anonymousID: UUID,
        timestamp: Date = Date()
    ) -> AnalyticsProviderCaptureResult {
        guard inFlightTasks.count < Self.maximumInFlightRequests else {
            return .rejected(.rateLimited)
        }
        guard AnalyticsSanitizer.isEventValid(event) else {
            return .rejected(.invalidPropertyValue)
        }
        guard
            let request = Self.makeRequest(
                event: event,
                anonymousID: anonymousID,
                projectToken: projectToken,
                endpoint: endpoint,
                timestamp: timestamp
            )
        else {
            return .rejected(.deliveryUnavailable)
        }

        let task = session.dataTask(with: request)
        inFlightTasks[task.taskIdentifier] = task
        task.resume()
        return .submitted
    }

    func cancelInFlightRequests() {
        // Cancellation is asynchronous. Keep tasks counted until URLSession's
        // completion callback retires them so a rapid opt-out/opt-in cannot
        // exceed the four-request network bound.
        for task in inFlightTasks.values {
            task.cancel()
        }
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeRequest(
        event: SanitizedAnalyticsEvent,
        anonymousID: UUID,
        projectToken: String,
        endpoint: URL,
        timestamp: Date = Date()
    ) -> URLRequest? {
        guard !projectToken.isEmpty,
            endpoint.absoluteString == AnalyticsProviderConfiguration.posthogCaptureEndpoint,
            AnalyticsSanitizer.isEventValid(event)
        else { return nil }

        var properties = providerProperties(event)
        properties["$process_person_profile"] = false
        properties["$geoip_disable"] = true
        let envelope: [String: Any] = [
            "api_key": projectToken,
            "event": event.name.rawValue,
            "distinct_id": anonymousID.uuidString,
            "properties": properties,
            "timestamp": timestampFormatter.string(from: timestamp),
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
            let body = try? JSONSerialization.data(withJSONObject: envelope)
        else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func providerProperties(
        _ event: SanitizedAnalyticsEvent
    ) -> [String: Any] {
        event.properties.reduce(into: [:]) { result, property in
            let (key, value) = property
            switch value {
            case .integer(let raw): result[key.rawValue] = raw
            case .token(let raw): result[key.rawValue] = raw
            }
        }
    }

    private func requestDidComplete(
        taskID: Int,
        statusCode: Int?,
        error: (any Error)?
    ) {
        guard inFlightTasks.removeValue(forKey: taskID) != nil else { return }
        if let error = error as? URLError, error.code == .cancelled {
            return
        }
        guard error == nil, let statusCode, (200..<300).contains(statusCode) else {
            logger.notice(
                "analytics request did not receive a successful response status=\(statusCode ?? 0, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            return
        }
    }
}

final class PostHogCaptureSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let completion: @Sendable (Int, Int?, (any Error)?) -> Void

    init(completion: @escaping @Sendable (Int, Int?, (any Error)?) -> Void) {
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The capture endpoint has no required redirect. Reject all redirects
        // so neither the project token nor payload can cross the fixed origin.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        completion(task.taskIdentifier, (task.response as? HTTPURLResponse)?.statusCode, error)
    }
}
