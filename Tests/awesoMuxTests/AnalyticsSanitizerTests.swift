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

    @Test("usage events drop below product_usage; error events pass at error_reports")
    func consentTiers() {
        let usage: [AnalyticsEventInput] = [
            .appLaunched(
                AppLaunchSnapshot(
                    appVersion: "1.0", buildNumber: "1", macOSMajor: 15, macOSMinor: 5,
                    cpuArchitecture: "arm64"
                )),
            .sessionCreated(
                shape: WorkspaceShapeSnapshot(sessionCount: 1, paneCount: 1, groupCount: 1),
                sessionKind: .local,
                agentKind: nil
            ),
            .agentSessionStarted(kind: .codex, initialState: .running, usesReliableHooks: true),
            .agentStateChanged(kind: .codex, previous: .running, next: .done, source: .hook),
            .workspaceGroupChanged(action: .added, shape: WorkspaceShapeSnapshot(sessionCount: 2, paneCount: 3, groupCount: 2)),
            .settingsChanged(area: .general),
            .diagnosticsOpened(section: .overview),
        ]
        for input in usage {
            #expect(sanitizer.sanitize(input, consent: .errorReports) == .dropped(.consentInsufficient))
            if case .dropped = sanitizer.sanitize(input, consent: .productUsage) {
                Issue.record("usage event unexpectedly dropped at product_usage: \(input)")
            }
        }
        let error = AnalyticsEventInput.errorReported(
            AnalyticsErrorContext(featureArea: .runtime, errorKind: .runtimeEventRejected)
        )
        if case .dropped = sanitizer.sanitize(error, consent: .errorReports) {
            Issue.record("error event unexpectedly dropped at error_reports")
        }
        if case .dropped = sanitizer.sanitize(.consentChanged(to: .errorReports), consent: .errorReports) {
            Issue.record("consent change unexpectedly dropped at error_reports")
        }
    }

    @Test("app launch payload maps versions, integers, and architecture")
    func appLaunchedMapping() throws {
        let result = sanitizer.sanitize(
            .appLaunched(
                AppLaunchSnapshot(
                    appVersion: "1.4.0", buildNumber: "203", macOSMajor: 15, macOSMinor: 5,
                    cpuArchitecture: "arm64"
                )),
            consent: .productUsage
        )
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.name == .appLaunched)
        #expect(event.properties[.appVersion] == .version("1.4.0"))
        #expect(event.properties[.buildNumber] == .version("203"))
        #expect(event.properties[.macosVersionMajor] == .integer(15))
        #expect(event.properties[.macosVersionMinor] == .integer(5))
        #expect(event.properties[.cpuArch] == .token("arm64"))
    }

    @Test(
        "session creation maps locality and allowlisted context",
        arguments: [
            (AnalyticsSessionKind.local, "local"),
            (.remote, "remote"),
            (.unknown, "unknown"),
        ]
    )
    func sessionCreatedMapping(sessionKind: AnalyticsSessionKind, expectedToken: String) throws {
        let result = sanitizer.sanitize(
            .sessionCreated(
                shape: WorkspaceShapeSnapshot(sessionCount: 7, paneCount: 2, groupCount: 1),
                sessionKind: sessionKind,
                agentKind: .claudeCode
            ),
            consent: .productUsage
        )
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.name == .sessionCreated)
        #expect(event.properties[.sessionCountBucket] == .bucket(.fourPlus))
        #expect(event.properties[.paneCountBucket] == .bucket(.twoToThree))
        #expect(event.properties[.workspaceGroupCountBucket] == .bucket(.one))
        #expect(event.properties[.sessionKind] == .token(expectedToken))
        #expect(event.properties[.agentKind] == .token("claude_code"))
        #expect(event.properties[.schemaVersion] == .integer(analyticsSchemaVersion))
        #expect(event.properties[.consentLevel] == .token("product_usage"))
        #expect(
            Set(event.properties.keys) == [
                .sessionCountBucket,
                .paneCountBucket,
                .workspaceGroupCountBucket,
                .sessionKind,
                .agentKind,
                .schemaVersion,
                .consentLevel,
            ]
        )
    }

    @Test("session creation omits absent agent kind without adding other context")
    func sessionCreatedWithoutAgentKind() throws {
        let result = sanitizer.sanitize(
            .sessionCreated(
                shape: WorkspaceShapeSnapshot(sessionCount: 1, paneCount: 1, groupCount: 0),
                sessionKind: .local,
                agentKind: nil
            ),
            consent: .productUsage
        )
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(
            Set(event.properties.keys) == [
                .sessionCountBucket,
                .paneCountBucket,
                .workspaceGroupCountBucket,
                .sessionKind,
                .schemaVersion,
                .consentLevel,
            ]
        )
    }

    @Test("agent state change carries slugs and event source")
    func agentStateChangedMapping() throws {
        let result = sanitizer.sanitize(
            .agentStateChanged(kind: .claudeCode, previous: .running, next: .needsAttention, source: .detected),
            consent: .productUsage
        )
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.properties[.agentKind] == .token("claude_code"))
        #expect(event.properties[.previousAgentState] == .token("running"))
        #expect(event.properties[.nextAgentState] == .token("needs_attention"))
        #expect(event.properties[.agentEventSource] == .token("detected"))
    }

    @Test("workspace shape buckets counts")
    func workspaceShapeMapping() throws {
        let result = sanitizer.sanitize(
            .workspaceGroupChanged(
                action: .removed,
                shape: WorkspaceShapeSnapshot(sessionCount: 7, paneCount: 2, groupCount: 1)
            ),
            consent: .productUsage
        )
        guard case .event(let event) = result else {
            Issue.record("expected event, got \(result)")
            return
        }
        #expect(event.properties[.action] == .token("removed"))
        #expect(event.properties[.sessionCountBucket] == .bucket(.fourPlus))
        #expect(event.properties[.paneCountBucket] == .bucket(.twoToThree))
        #expect(event.properties[.workspaceGroupCountBucket] == .bucket(.one))
    }

    @Test(
        "count bucketing",
        arguments: [
            (0, CountBucket.zero),
            (1, .one),
            (2, .twoToThree),
            (3, .twoToThree),
            (4, .fourPlus),
            (17, .fourPlus),
            (-1, .zero),
        ]
    )
    func countBucketing(count: Int, expected: CountBucket) {
        #expect(CountBucket(count: count) == expected)
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
        arguments: ["claude-code", "arm64", "remote", "error_reports", "0"]
    )
    func tokenAcceptance(raw: String) {
        #expect(AnalyticsPropertyValue.token(validating: raw) != nil)
    }

    @Test(
        "version factory",
        arguments: [
            ("1.4.0", true),
            ("203", true),
            ("1.4.0-beta", false),
            ("/etc/hosts", false),
            ("", false),
        ]
    )
    func versionFactory(raw: String, accepted: Bool) {
        #expect((AnalyticsPropertyValue.version(validating: raw) != nil) == accepted)
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
