import AwesoMuxConfig
import Foundation
import Testing

@testable import awesoMux

@Suite("AnalyticsSanitizer")
struct AnalyticsSanitizerTests {
    private let sanitizer = AnalyticsSanitizer()

    @Test("consent off drops everything")
    func consentOffDrops() {
        #expect(sanitizer.sanitize(.testPing, consent: .off) == .dropped(.analyticsDisabled))
    }

    @Test("test ping maps to allowlisted payload with mandatory context")
    func testPingMapping() throws {
        let result = sanitizer.sanitize(.testPing, consent: .errorReports)
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.name == .testPing)
        #expect(event.properties[.schemaVersion] == .integer(analyticsSchemaVersion))
        #expect(event.properties[.consentLevel] == .token("error_reports"))
        #expect(event.properties.count == 2)
    }

    @Test("consent change rides amx_settings_changed with the new level")
    func consentChangedMapping() throws {
        let result = sanitizer.sanitize(.consentChanged(to: .productUsage), consent: .productUsage)
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.name == .settingsChanged)
        #expect(event.properties[.settingsArea] == .token("analytics"))
        #expect(event.properties[.consentLevel] == .token("product_usage"))
    }

    @Test("shipped events pass when analytics is enabled")
    func enabledConsent() {
        if case .dropped = sanitizer.sanitize(.testPing, consent: .errorReports) {
            Issue.record("test ping unexpectedly dropped at error_reports")
        }
        if case .dropped = sanitizer.sanitize(.consentChanged(to: .errorReports), consent: .errorReports) {
            Issue.record("consent change unexpectedly dropped at error_reports")
        }
        let launch = AppLaunchSnapshot(
            appVersion: "1.2.3", buildNumber: "45", macOSMajor: 15, macOSMinor: 5, cpuArchitecture: "arm64")
        if case .dropped = sanitizer.sanitize(.appLaunched(launch), consent: .productUsage) {
            Issue.record("app launch unexpectedly dropped at product_usage")
        }
        let error = AnalyticsErrorContext(
            featureArea: .terminal,
            errorKind: .terminalFailed,
            remote: AnalyticsRemoteContext(presence: .remote, activePaneRemote: true, remotePaneCount: 4)
        )
        if case .dropped = sanitizer.sanitize(.errorReported(error), consent: .errorReports) {
            Issue.record("handled error unexpectedly dropped at error_reports")
        }
        if case .dropped = sanitizer.sanitize(.diagnosticsOpened(section: .analytics), consent: .productUsage) {
            Issue.record("Diagnostics opening unexpectedly dropped at product_usage")
        }
    }

    @Test("product events require product usage consent")
    func productConsentGate() {
        let launch = AppLaunchSnapshot(
            appVersion: "1.2.3", buildNumber: "45", macOSMajor: 15, macOSMinor: 5, cpuArchitecture: "arm64")

        #expect(
            sanitizer.sanitize(.appLaunched(launch), consent: .errorReports)
                == .dropped(.consentInsufficient))
        #expect(
            sanitizer.sanitize(.diagnosticsOpened(section: .overview), consent: .errorReports)
                == .dropped(.consentInsufficient))
    }

    @Test("handled error carries only coarse remote context")
    func handledErrorMapping() throws {
        let input = AnalyticsEventInput.errorReported(
            AnalyticsErrorContext(
                featureArea: .terminal,
                errorKind: .terminalFailed,
                remote: AnalyticsRemoteContext(
                    presence: .remote,
                    activePaneRemote: true,
                    remotePaneCount: 4
                )))
        guard case .event(let event) = sanitizer.sanitize(input, consent: .errorReports) else {
            Issue.record("expected sanitized handled-error event")
            return
        }

        #expect(event.name == .errorReported)
        #expect(event.properties[.featureArea] == .token("terminal"))
        #expect(event.properties[.errorKind] == .token("terminal_failed"))
        #expect(event.properties[.remoteContext] == .token("remote"))
        #expect(event.properties[.activePaneRemote] == .bool(true))
        #expect(event.properties[.remotePaneCountBucket] == .bucket(.fourPlus))
        #expect(AnalyticsSanitizer.isEventValid(event))
    }

    @Test(
        "token factory rejects user-content shapes",
        arguments: [
            "/Users/example/project",
            "user@host",
            "has space",
            "Uppercase",
            "~",
            "",
            String(repeating: "a", count: 33),
        ]
    )
    func tokenRejection(raw: String) {
        #expect(AnalyticsPropertyValue.token(validating: raw) == nil)
    }

    @Test(
        "token factory accepts enum-like slugs",
        arguments: ["analytics", "error_reports", "product_usage"]
    )
    func tokenAcceptance(raw: String) {
        #expect(AnalyticsPropertyValue.token(validating: raw) != nil)
    }

    @Test("property key allowlist contains no forbidden identifiers")
    func allowlistDocumentation() {
        let forbiddenFragments = [
            "path", "cwd", "hostname", "host_name", "username", "user_name",
            "email", "title", "name", "prompt", "command", "env", "ip",
        ]
        for key in AnalyticsPropertyKey.allCases {
            for fragment in forbiddenFragments {
                #expect(
                    !key.rawValue.contains(fragment),
                    "allowlist key \(key.rawValue) contains forbidden fragment \(fragment)"
                )
            }
        }
    }
}
