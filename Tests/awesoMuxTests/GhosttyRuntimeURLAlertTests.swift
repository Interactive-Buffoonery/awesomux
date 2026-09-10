import Foundation
import Testing
@testable import awesoMux
import AwesoMuxCore

@Suite("GhosttyRuntime URL alert body")
struct GhosttyRuntimeURLAlertTests {
    @Test("mailto warning includes path and query recipients")
    @MainActor
    func mailtoWarningIncludesPathAndQueryRecipients() throws {
        let url = try #require(URL(string: "mailto:alice@example.com?to=bob@example.com&to=carol@example.com&body=hi"))

        let body = GhosttyRuntime.alertBodyForBlockedURL(
            url,
            reason: .mailtoWithParameters,
            displayHost: nil,
            punycodeHost: nil
        )

        #expect(body.contains("To: \u{2068}alice@example.com, bob@example.com, carol@example.com\u{2069}"))
    }

    @Test("full URL display scrubs unsafe line separators without truncating")
    @MainActor
    func fullURLDisplayScrubsUnsafeLineSeparatorsWithoutTruncating() throws {
        let url = try #require(URL(string: "https://example.com/path\u{2028}Resolves to: https://safe.example"))

        let body = GhosttyRuntime.alertBodyForBlockedURL(
            url,
            reason: .pathHasUnsafeCodepoints,
            displayHost: "example.com",
            punycodeHost: "example.com"
        )

        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0x2028)!))
        #expect(!body.contains("\nResolves to: https://safe.example"))
        #expect(body.contains("Full URL: https://example.com/path%E2%80%A8Resolves%20to:%20https://safe.example"))
    }
    @Test("full URL preserves a decision-changing suffix beyond 200 characters")
    @MainActor
    func fullURLPreservesLongSuffix() throws {
        let raw =
            "https://example.com/" + String(repeating: "path", count: 100)
            + "?action=delete-all&destination=untrusted.example"
        let url = try #require(URL(string: raw))
        let body = GhosttyRuntime.alertBodyForBlockedURL(
            url, reason: .pathHasUnsafeCodepoints, displayHost: nil, punycodeHost: nil
        )
        #expect(body.contains("Full URL: " + url.absoluteString))
        #expect(!body.contains("…"))
    }

    @Test("decoded mailto subjects preserve content beyond the former field cap")
    @MainActor
    func mailtoSubjectPreservesLongSuffix() throws {
        let subject = String(repeating: "a", count: 180) + "-decision-changing-suffix"
        let url = try #require(URL(string: "mailto:alice@example.com?subject=" + subject))
        let body = GhosttyRuntime.alertBodyForBlockedURL(
            url, reason: .mailtoWithParameters, displayHost: nil, punycodeHost: nil
        )
        #expect(body.contains("Subject: \u{2068}" + subject + "\u{2069}"))
        #expect(!body.contains("…"))
    }

}
