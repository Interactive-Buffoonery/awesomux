import Foundation
import os
import Testing

@testable import awesoMux

@MainActor
@Suite("PostHog Capture provider", .serialized)
struct PostHogCaptureProviderTests {
    @Test("the direct transport has no PostHog SDK dependency")
    func noSDKDependency() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: root.appending(path: "Package.swift"),
            encoding: .utf8
        )
        let resolved = try String(
            contentsOf: root.appending(path: "Package.resolved"),
            encoding: .utf8
        )

        #expect(!manifest.lowercased().contains("posthog-ios"))
        #expect(!resolved.lowercased().contains("posthog-ios"))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "Resources/Licenses/PostHog").path
            ))
    }

    @Test("request envelope is exact, anonymous, and GeoIP-disabled")
    func requestEnvelope() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = try Self.testEvent()
        let endpoint = try #require(
            URL(string: AnalyticsProviderConfiguration.posthogCaptureEndpoint)
        )
        let request = try #require(
            PostHogCaptureProvider.makeRequest(
                event: event,
                anonymousID: id,
                projectToken: "phc_test",
                endpoint: endpoint,
                timestamp: timestamp
            ))

        #expect(request.url?.absoluteString == AnalyticsProviderConfiguration.posthogCaptureEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let body = try #require(request.httpBody)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(Set(envelope.keys) == ["api_key", "event", "distinct_id", "properties", "timestamp"])
        #expect(envelope["api_key"] as? String == "phc_test")
        #expect(envelope["event"] as? String == AnalyticsEventName.testPing.rawValue)
        #expect(envelope["distinct_id"] as? String == id.uuidString)
        #expect(envelope["timestamp"] as? String == ISO8601DateFormatter().string(from: timestamp))
        let properties = try #require(envelope["properties"] as? [String: Any])
        #expect(
            Set(properties.keys) == [
                AnalyticsPropertyKey.schemaVersion.rawValue,
                AnalyticsPropertyKey.consentLevel.rawValue,
                "$process_person_profile",
                "$geoip_disable",
            ])
        #expect(properties[AnalyticsPropertyKey.schemaVersion.rawValue] as? Int == analyticsSchemaVersion)
        #expect(properties[AnalyticsPropertyKey.consentLevel.rawValue] as? String == "error_reports")
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$geoip_disable"] as? Bool == true)
    }

    @Test("transport configuration has no cookie, cache, or credential stores")
    func sessionConfiguration() {
        let configuration = PostHogCaptureProvider.makeSessionConfiguration()

        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 15)
        #expect(!configuration.waitsForConnectivity)
    }

    @Test("submission creates exactly one request to the fixed endpoint")
    func interceptedSubmission() async throws {
        URLProtocolRecorder.reset(mode: .respond(statusCode: 202))
        let configuration = PostHogCaptureProvider.makeSessionConfiguration()
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let provider = PostHogCaptureProvider(
            projectToken: "phc_test",
            sessionConfiguration: configuration
        )

        #expect(provider.capture(try Self.testEvent(), anonymousID: UUID()) == .submitted)
        let requests = try await Self.waitForRequests(count: 1)

        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == AnalyticsProviderConfiguration.posthogCaptureEndpoint)
        #expect(requests[0].httpMethod == "POST")
        try await Self.waitForInFlightCount(0, provider: provider)
        #expect(URLProtocolRecorder.requests.count == 1)
    }

    @Test("in-flight cap drops excess work and cancellation stops transport tasks")
    func inFlightCap() async throws {
        URLProtocolRecorder.reset(mode: .hang)
        let configuration = PostHogCaptureProvider.makeSessionConfiguration()
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let provider = PostHogCaptureProvider(
            projectToken: "phc_test",
            sessionConfiguration: configuration
        )
        let event = try Self.testEvent()

        for _ in 0..<PostHogCaptureProvider.maximumInFlightRequests {
            #expect(provider.capture(event, anonymousID: UUID()) == .submitted)
        }
        #expect(provider.capture(event, anonymousID: UUID()) == .rejected(.rateLimited))
        #expect(provider.inFlightRequestCount == PostHogCaptureProvider.maximumInFlightRequests)
        _ = try await Self.waitForRequests(count: PostHogCaptureProvider.maximumInFlightRequests)

        provider.cancelInFlightRequests()
        #expect(provider.inFlightRequestCount == PostHogCaptureProvider.maximumInFlightRequests)
        #expect(provider.capture(event, anonymousID: UUID()) == .rejected(.rateLimited))
        try await Self.waitForStopCount(PostHogCaptureProvider.maximumInFlightRequests)
        try await Self.waitForInFlightCount(0, provider: provider)

        #expect(provider.inFlightRequestCount == 0)
        #expect(URLProtocolRecorder.stopCount == PostHogCaptureProvider.maximumInFlightRequests)
    }

    @Test("invalid token or endpoint fails before creating a task")
    func invalidConfiguration() throws {
        let event = try Self.testEvent()
        let id = UUID()
        let validEndpoint = try #require(URL(string: AnalyticsProviderConfiguration.posthogCaptureEndpoint))

        #expect(
            PostHogCaptureProvider.makeRequest(
                event: event,
                anonymousID: id,
                projectToken: "",
                endpoint: validEndpoint
            ) == nil)
        let invalidEndpoint = try #require(URL(string: "https://example.com/i/v0/e/"))
        #expect(
            PostHogCaptureProvider.makeRequest(
                event: event,
                anonymousID: id,
                projectToken: "phc_test",
                endpoint: invalidEndpoint
            ) == nil)
        let tamperedEvent = SanitizedAnalyticsEvent(
            name: .testPing,
            properties: [.schemaVersion: .token("not-an-integer")]
        )
        #expect(
            PostHogCaptureProvider.makeRequest(
                event: tamperedEvent,
                anonymousID: id,
                projectToken: "phc_test",
                endpoint: validEndpoint
            ) == nil)
        let semanticallyInvalidEvent = SanitizedAnalyticsEvent(
            name: .settingsChanged,
            properties: [
                .schemaVersion: .integer(analyticsSchemaVersion),
                .consentLevel: .token("product_usage"),
            ]
        )
        #expect(
            PostHogCaptureProvider.makeRequest(
                event: semanticallyInvalidEvent,
                anonymousID: id,
                projectToken: "phc_test",
                endpoint: validEndpoint
            ) == nil)
    }

    @Test("redirect delegate rejects every redirect")
    func redirectsAreRejected() throws {
        let delegate = PostHogCaptureSessionDelegate { _, _, _ in }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let endpoint = try #require(
            URL(string: AnalyticsProviderConfiguration.posthogCaptureEndpoint)
        )
        let redirectEndpoint = try #require(URL(string: "https://example.com/"))
        let original = session.dataTask(with: endpoint)
        let response = try #require(
            HTTPURLResponse(
                url: endpoint,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://example.com/"]
            ))
        var decision: URLRequest??

        delegate.urlSession(
            session,
            task: original,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectEndpoint)
        ) { decision = .some($0) }

        #expect(decision != nil)
        #expect(decision! == nil)
        session.invalidateAndCancel()
    }

    private static func testEvent() throws -> SanitizedAnalyticsEvent {
        guard
            case .event(let event) = AnalyticsSanitizer().sanitize(
                .testPing,
                consent: .errorReports
            )
        else {
            throw TestError.sanitizationFailed
        }
        return event
    }

    private static func waitForRequests(count: Int) async throws -> [URLRequest] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let requests = URLProtocolRecorder.requests
            if requests.count >= count { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        return URLProtocolRecorder.requests
    }

    private static func waitForStopCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, URLProtocolRecorder.stopCount < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(URLProtocolRecorder.stopCount == count)
    }

    private static func waitForInFlightCount(
        _ count: Int,
        provider: PostHogCaptureProvider
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, provider.inFlightRequestCount != count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.inFlightRequestCount == count)
    }

    private enum TestError: Error {
        case sanitizationFailed
    }
}

private enum URLProtocolRecorder {
    enum Mode: Sendable {
        case respond(statusCode: Int)
        case hang
    }

    private struct State: Sendable {
        var mode: Mode = .respond(statusCode: 200)
        var requests: [URLRequest] = []
        var stopCount = 0
    }

    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    static var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    static var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    static func reset(mode: Mode) {
        state.withLock {
            $0.mode = mode
            $0.requests = []
            $0.stopCount = 0
        }
    }

    static func record(_ request: URLRequest) -> Mode {
        state.withLock {
            $0.requests.append(request)
            return $0.mode
        }
    }

    static func recordStop() {
        state.withLock { $0.stopCount += 1 }
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch URLProtocolRecorder.record(request) {
        case .hang:
            return
        case .respond(let statusCode):
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        URLProtocolRecorder.recordStop()
    }
}
