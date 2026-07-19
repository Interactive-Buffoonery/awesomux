import Foundation
import Testing

@testable import AwesoMuxConfig

@Suite("AnalyticsConfig")
struct AnalyticsConfigTests {
    @Test("missing section decodes to defaults")
    func missingSectionDefaults() throws {
        let config = try TOMLConfigCodec().decode("[general]\n")
        #expect(config.analytics == .defaultValue)
        #expect(config.analytics.consentLevel == .off)
        #expect(config.analytics.retainLocalEventLog)
        #expect(config.analytics.posthogHost == "https://us.i.posthog.com")
    }

    @Test("full section round-trips through TOML")
    func roundTrip() throws {
        let codec = TOMLConfigCodec()
        var config = AwesoMuxConfig.defaultValue
        config.analytics.consentLevel = .errorReports
        config.analytics.retainLocalEventLog = false

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)
        #expect(decoded.analytics == config.analytics)
    }

    @Test("unknown consent level rejects the config")
    func unknownConsentLevelRejects() {
        let toml = "[analytics]\nconsent_level = \"maximum\"\n"
        #expect(throws: (any Error).self) {
            try TOMLConfigCodec().decode(toml)
        }
    }

    @Test("non-https posthog host fails validation")
    func nonHTTPSHostRejected() {
        let toml = "[analytics]\nposthog_host = \"http://us.i.posthog.com\"\n"
        #expect(throws: (any Error).self) {
            try TOMLConfigCodec().decode(toml)
        }
    }

    @Test("uppercase HTTPS scheme validates")
    func uppercaseHTTPSSchemeAccepted() throws {
        let toml = "[analytics]\nposthog_host = \"HTTPS://us.i.posthog.com\"\n"
        let config = try TOMLConfigCodec().decode(toml)
        #expect(config.analytics.posthogHost == "HTTPS://us.i.posthog.com")
    }

}
