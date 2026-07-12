import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("URLClassifier")
struct URLClassifierTests {
    // MARK: - openDirect path

    @Test("plain ASCII https opens direct")
    func plainAsciiHTTPSOpensDirect() throws {
        let url = try #require(URL(string: "https://example.com/path?q=1"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("plain ASCII http opens direct")
    func plainAsciiHTTPOpensDirect() throws {
        let url = try #require(URL(string: "http://example.com"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("plain mailto with no query opens direct")
    func plainMailtoOpensDirect() throws {
        let url = try #require(URL(string: "mailto:foo@example.com"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("mailto with empty subject value opens direct")
    func mailtoEmptyParamValueOpensDirect() throws {
        // `mailto:foo@example.com?subject=` — empty value isn't phishing.
        let url = try #require(URL(string: "mailto:foo@example.com?subject="))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    // MARK: - blockConfirm: nonAsciiHost

    @Test("Cyrillic homograph host triggers block-confirm with Unicode + punycode forms")
    func cyrillicHomographBlocksConfirm() throws {
        // U+0440 CYRILLIC SMALL LETTER ER masquerading as Latin 'p'.
        let url = try #require(URL(string: "https://\u{0440}aypal.com/login"))
        let decision = URLClassifier.classify(url)
        guard case let .blockConfirm(reason, displayHost, punycodeHost) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
        // displayHost should be the Unicode form (what we show the user).
        #expect(displayHost?.unicodeScalars.contains(where: { $0.value > 0x7F }) == true)
        // punycodeHost is the `xn--…` form (what gets resolved).
        #expect(punycodeHost?.contains("xn--") == true)
        #expect(punycodeHost != displayHost)
    }

    @Test("pure-Cyrillic host also blocks (strict v1 posture)")
    func pureCyrillicHostBlocks() throws {
        let url = try #require(URL(string: "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}.\u{0440}\u{0444}/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("punycode-encoded host (xn--) is decoded for display and still blocks")
    func punycodeSourceURLDecodesToUnicodeAndBlocks() throws {
        // Source URL is in punycode form. Foundation's URLComponents.host
        // decodes xn-- back to Unicode for display; classifier should
        // surface that as displayHost while keeping the original xn-- as
        // punycodeHost.
        let url = try #require(URL(string: "https://xn--aypal-58d.com/login"))
        let decision = URLClassifier.classify(url)
        guard case let .blockConfirm(reason, displayHost, punycodeHost) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
        #expect(displayHost?.unicodeScalars.contains(where: { $0.value > 0x7F }) == true)
        #expect(punycodeHost == "xn--aypal-58d.com")
    }

    // MARK: - blockConfirm: mailtoWithParameters

    @Test("mailto with body parameter blocks")
    func mailtoBodyBlocks() throws {
        let url = try #require(URL(string: "mailto:victim@example.com?body=Please%20click%20here"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .mailtoWithParameters)
    }

    @Test("mailto with subject parameter blocks")
    func mailtoSubjectBlocks() throws {
        let url = try #require(URL(string: "mailto:foo@example.com?subject=Urgent"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .mailtoWithParameters, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("mailto with cc parameter blocks")
    func mailtoCCBlocks() throws {
        let url = try #require(URL(string: "mailto:foo@example.com?cc=spy@evil.example"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .mailtoWithParameters, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("mailto with bcc parameter blocks")
    func mailtoBCCBlocks() throws {
        let url = try #require(URL(string: "mailto:foo@example.com?bcc=spy@evil.example"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .mailtoWithParameters, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("mailto with unknown query parameter is permitted")
    func mailtoUnknownQueryParameterOpensDirect() throws {
        // Foundation parses `mailto:?foo=bar` even though it's unusual.
        // Only the four phishing-prefill parameters trip the gate.
        let url = try #require(URL(string: "mailto:foo@example.com?in-reply-to=abc"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    // MARK: - blockConfirm: disallowedScheme

    @Test("file scheme blocks")
    func fileSchemeBlocks() throws {
        let url = try #require(URL(string: "file:///etc/passwd"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .disallowedScheme, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("javascript scheme blocks")
    func javascriptSchemeBlocks() throws {
        let url = try #require(URL(string: "javascript:alert(1)"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .disallowedScheme, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("custom app scheme blocks")
    func customAppSchemeBlocks() throws {
        // Common attacker target — VSCode/Slack/Obsidian URL handlers
        // take side-effecting actions on attacker-controlled payloads.
        let url = try #require(URL(string: "vscode://settings/sync"))
        #expect(
            URLClassifier.classify(url)
                == .blockConfirm(reason: .disallowedScheme, displayHost: nil, punycodeHost: nil)
        )
    }

    @Test("scheme matching is case-insensitive")
    func schemeMatchingIsCaseInsensitive() throws {
        let url = try #require(URL(string: "HTTPS://example.com"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    // MARK: - blockConfirm: embeddedUserInfo

    @Test("HTTPS with userinfo blocks (classic user@host phishing)")
    func userinfoPhishingBlocks() throws {
        // The classic disguise: visible prefix says paypal, real host is evil.
        let url = try #require(URL(string: "https://www.paypal.com@evil.example/login"))
        let decision = URLClassifier.classify(url)
        guard case let .blockConfirm(reason, displayHost, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .embeddedUserInfo)
        #expect(displayHost == "evil.example")
    }

    @Test("HTTPS with user:password@host blocks")
    func userPasswordPhishingBlocks() throws {
        let url = try #require(URL(string: "https://user:pass@example.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .embeddedUserInfo)
    }

    // MARK: - blockConfirm: missingHost

    @Test("HTTPS with no host blocks")
    func httpsWithNoHostBlocks() throws {
        // `https:///path` parses as a URL with scheme set but host nil.
        let url = try #require(URL(string: "https:///path"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .missingHost)
    }

    // MARK: - blockConfirm: pathHasUnsafeCodepoints

    @Test("path with RTL override (U+202E) blocks")
    func pathRTLOverrideBlocks() throws {
        // The classic "rename evil.exe to gnp.txt" extension-spoof trick.
        let url = try #require(URL(string: "https://example.com/path/\u{202E}gnp.exe"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("path with zero-width space blocks")
    func pathZeroWidthBlocks() throws {
        let url = try #require(URL(string: "https://example.com/login\u{200B}suffix"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("clean ASCII path with percent-encoded UTF-8 opens direct")
    func cleanPercentEncodedPathOpensDirect() throws {
        // `café` percent-encoded → `caf%C3%A9` — Foundation decodes
        // the path on URLComponents.path; the decoded form contains
        // `é` (U+00E9) which is NOT in the unsafe codepoint set.
        let url = try #require(URL(string: "https://example.com/caf%C3%A9/menu.pdf"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    // MARK: - blockConfirm: mailto extra cases

    @Test("mailto with `to` query parameter blocks (RFC 6068 recipient field)")
    func mailtoToParameterBlocks() throws {
        let url = try #require(URL(string: "mailto:?to=victim@example.com"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .mailtoWithParameters)
    }

    @Test("mailto with uppercase parameter name still blocks")
    func mailtoUppercaseParameterBlocks() throws {
        let url = try #require(URL(string: "mailto:foo@example.com?SUBJECT=Urgent"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .mailtoWithParameters)
    }

    // MARK: - documented v1 gaps (IP-literal hosts open direct)

    @Test("localhost opens direct (v1 gap — dev workflow)")
    func localhostOpensDirect() throws {
        let url = try #require(URL(string: "http://localhost:3000/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("bare IPv4 literal opens direct (v1 gap — see classifier doc)")
    func bareIPv4OpensDirect() throws {
        let url = try #require(URL(string: "http://192.0.2.1/admin"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("IPv6 literal opens direct (v1 gap — see classifier doc)")
    func ipv6LiteralOpensDirect() throws {
        let url = try #require(URL(string: "http://[::1]/admin"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    // MARK: - additional embeddedUserInfo / control-char cases from review pass 2

    @Test("password-only userinfo blocks")
    func passwordOnlyUserinfoBlocks() throws {
        // `https://:foo@evil.example/` — empty user, non-empty password.
        // Foundation parses this as valid userinfo; it has the same
        // host-disguising shape as a full `user@host` prefix.
        let url = try #require(URL(string: "https://:secret@evil.example/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .embeddedUserInfo)
    }

    @Test("host with percent-decoded control character blocks")
    func hostWithControlCharacterBlocks() throws {
        // `exa%0Ample.com` decodes to a host with a literal newline.
        // Pure ASCII otherwise — passes the non-ASCII and xn-- checks,
        // but absolutely malformed and a vector for forging fake lines
        // into the alert body.
        let url = try #require(URL(string: "https://exa%0Ample.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test(
        "host with percent-decoded reserved delimiter blocks",
        arguments: [
            ("https://paypal.com%40evil.example/", "@"),
            ("https://exa%2Fmple.com/", "/"),
            ("https://exa%3Fmple.com/", "?"),
            ("https://exa%23mple.com/", "#"),
            ("https://exa%5Bmple.com/", "["),
            ("https://exa%5Dmple.com/", "]")
        ]
    )
    func hostWithPercentDecodedReservedDelimiterBlocks(
        rawURL: String,
        delimiter: String
    ) throws {
        let url = try #require(URL(string: rawURL))
        let decision = URLClassifier.classify(url)
        guard case let .blockConfirm(reason, displayHost, _) = decision else {
            Issue.record("Expected blockConfirm for delimiter \(delimiter), got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
        #expect(displayHost?.contains(delimiter) == true)
    }

    @Test("path with percent-decoded LF (U+000A) blocks")
    func pathWithPercentDecodedNewlineBlocks() throws {
        // `https://example.com/path%0Aspoof` decodes to a path with
        // a literal newline. ASCII host, no userinfo, no `xn--`, but
        // the path contains a C0 control — alert-body injection vector.
        let url = try #require(URL(string: "https://example.com/path%0Aspoof"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("path with U+2028 (LINE SEPARATOR) blocks")
    func pathWithLineSeparatorBlocks() throws {
        let url = try #require(URL(string: "https://example.com/a\u{2028}b"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("path with U+2029 (PARAGRAPH SEPARATOR) blocks")
    func pathWithParagraphSeparatorBlocks() throws {
        let url = try #require(URL(string: "https://example.com/a\u{2029}b"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("query with RTL override (U+202E) blocks")
    func queryRTLOverrideBlocks() throws {
        let url = try #require(URL(string: "https://example.com/search?q=value\u{202E}"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }

    @Test("fragment with zero-width space blocks")
    func fragmentZeroWidthBlocks() throws {
        let url = try #require(URL(string: "https://example.com/page#section\u{200B}"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .pathHasUnsafeCodepoints)
    }
}
