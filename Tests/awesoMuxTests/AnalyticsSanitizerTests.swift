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
