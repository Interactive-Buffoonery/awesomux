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

    // MARK: - blockConfirm/openDirect: TR39 mixed-script detection (INT-454)

    @Test("pure-Cyrillic host opens direct (TR39: single-script hosts aren't a homograph risk)")
    func pureCyrillicHostOpensDirect() throws {
        // яндекс.рф — every label is entirely Cyrillic.
        let url = try #require(URL(string: "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}.\u{0440}\u{0444}/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("pure-CJK host opens direct")
    func pureCJKHostOpensDirect() throws {
        // 日本語.jp — Han label plus an ASCII TLD label; each label alone
        // is single-script, so this must not read as "mixed" even though
        // the host as a whole isn't ASCII.
        let url = try #require(URL(string: "https://\u{65E5}\u{672C}\u{8A9E}.jp/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("non-Latin host with digits and a hyphen opens direct (Common script doesn't count as mixing)")
    func nonLatinHostWithDigitsAndHyphenOpensDirect() throws {
        let url = try #require(URL(string: "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}-2.\u{0440}\u{0444}/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("script mixing across labels (not within one) opens direct")
    func scriptMixingAcrossLabelsOpensDirect() throws {
        // яндекс.com — a pure-Cyrillic label followed by a pure-Latin TLD
        // label. TR39 mixing is a per-label property; different labels are
        // allowed to use different scripts.
        let url = try #require(URL(string: "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}.com/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("Latin+Cyrillic mixed within one label blocks (the confusable case)")
    func mixedScriptWithinOneLabelBlocks() throws {
        let url = try #require(URL(string: "https://p\u{0430}ypal.com/login"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("Latin Extended-D lookalike mixed with Cyrillic blocks")
    func latinExtendedDMixedWithCyrillicBlocks() throws {
        // U+A7CA LATIN CAPITAL LETTER S WITH SHORT STROKE + Cyrillic а —
        // a valid, punycode-encodable IDN host that exercises
        // UnicodeHygiene's Latin Extended-C/D/E coverage end to end.
        let url = try #require(URL(string: "https://\u{A7CA}\u{0430}.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test(
        "malformed punycode that fails to decode blocks, not opens direct",
        arguments: [
            "https://xn--a.com/",
            "https://good.xn--a.com/",
        ]
    )
    func malformedPunycodeDecodeFailureBlocks(rawURL: String) throws {
        // `xn--a` isn't valid punycode — Foundation's `URLComponents.host`
        // returns nil rather than the raw `xn--a.com` text (verified
        // empirically), while `url.host(percentEncoded:false)` still
        // returns the punycode form. A naive "check displayHost only" gate
        // would see nil and wave this through as openDirect — including
        // for a multi-label host where just one label fails to decode,
        // which blanks displayHost for the WHOLE host.
        let url = try #require(URL(string: rawURL))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm for \(rawURL), got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("punycode-encoded pure-script host opens direct")
    func punycodeEncodedPureScriptHostOpensDirect() throws {
        // xn--80adxhks.com decodes to москва.com — pure Cyrillic, encoded.
        let url = try #require(URL(string: "https://xn--80adxhks.com/"))
        #expect(URLClassifier.classify(url) == .openDirect)
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

    // MARK: - blockConfirm/openDirect: TR39 whole-script confusables (#143)

    @Test("verified whole-script attack xn--80ak6aa92e.com blocks with both host forms")
    func wholeScriptAttackPunycodeBlocks() throws {
        // xn--80ak6aa92e.com decodes to аррӏе.com — pure Cyrillic that reads
        // as "apple.com". No label mixes scripts, so the mixed-script gate
        // waves it through; the whole-script gate must catch it.
        let url = try #require(URL(string: "https://xn--80ak6aa92e.com/"))
        let decision = URLClassifier.classify(url)
        guard case let .blockConfirm(reason, displayHost, punycodeHost) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
        #expect(displayHost?.unicodeScalars.contains(where: { $0.value > 0x7F }) == true)
        #expect(punycodeHost?.contains("xn--") == true)
    }

    @Test("raw-Unicode whole-script host аррӏе.com blocks")
    func wholeScriptAttackRawUnicodeBlocks() throws {
        // Same host, delivered already decoded (аррӏе.com).
        let url = try #require(
            URL(string: "https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("a dangerous label blocks even beside a safe non-confusable sibling label")
    func wholeScriptConfusableLabelBesideSafeLabelBlocks() throws {
        // аррӏе.москва — the first label is a whole-script confusable, the
        // second (москва) is a legitimate Cyrillic word that is NOT all
        // lookalikes. Detection is per-label: the safe sibling must not
        // cancel the dangerous one (a whole-host implementation would miss
        // this because москва bails).
        let url = try #require(
            URL(
                string:
                    "https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.\u{043C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}/"
            ))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test(
        "every lookalike-table entry blocks as a single-label host",
        arguments: [
            "\u{0430}",  // а → a
            "\u{0441}",  // с → c
            "\u{0501}",  // ԁ → d
            "\u{0435}",  // е → e
            "\u{04BB}",  // һ → h
            "\u{0456}",  // і → i
            "\u{0458}",  // ј → j
            "\u{04CF}",  // ӏ → l
            "\u{043E}",  // о → o
            "\u{0440}",  // р → p
            "\u{051B}",  // ԛ → q
            "\u{0455}",  // ѕ → s
            "\u{051D}",  // ԝ → w
            "\u{0445}",  // х → x
            "\u{0443}",  // у → y
        ]
    )
    func everyLookalikeTableEntryBlocks(lookalike: String) throws {
        // Independently sourced from each entry's intended Latin twin, so a
        // wrong or omitted scalar in the classifier's table fails here.
        let url = try #require(URL(string: "https://\(lookalike).com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm for \(lookalike), got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("all-lookalike Cyrillic label with no brand context still blocks (documents FP policy)")
    func allLookalikeNonBrandLabelBlocks() throws {
        // сосо.com — every letter is a lookalike, so it soft-confirms even
        // though it's not spoofing a known brand. This is the accepted,
        // brand-list-free policy (issue #143 forbids a curated brand list):
        // conservative on the character set, not on the domain.
        let url = try #require(URL(string: "https://\u{0441}\u{043E}\u{0441}\u{043E}.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("single-character whole-script confusable label blocks")
    func singleCharWholeScriptConfusableBlocks() throws {
        // о.com — one Cyrillic о (looks like Latin o).
        let url = try #require(URL(string: "https://\u{043E}.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("digits and a hyphen do not rescue an all-lookalike label (still blocks)")
    func digitsAndHyphenInLookalikeLabelStillBlocks() throws {
        // аре-2.com — а/р/е are lookalikes; the ASCII digit and hyphen are
        // neutral and must not open the door.
        let url = try #require(URL(string: "https://\u{0430}\u{0440}\u{0435}-2.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("uppercase whole-script confusable host blocks")
    func uppercaseWholeScriptConfusableBlocks() throws {
        // АРРӀЕ.com — uppercase Cyrillic. Foundation lowercases the host and
        // the classifier lowercases the label, so the uppercase spoof lands
        // on the same lookalike set as its lowercase form.
        let url = try #require(
            URL(string: "https://\u{0410}\u{0420}\u{0420}\u{04C0}\u{0415}.com/"))
        let decision = URLClassifier.classify(url)
        guard case .blockConfirm(let reason, _, _) = decision else {
            Issue.record("Expected blockConfirm, got \(decision)")
            return
        }
        #expect(reason == .nonAsciiHost)
    }

    @Test("single non-lookalike Cyrillic letter opens direct")
    func singleNonLookalikeCyrillicLetterOpensDirect() throws {
        // я.com — я has no convincing Latin lookalike, so it is a real
        // single-script host, not a spoof.
        let url = try #require(URL(string: "https://\u{044F}.com/"))
        #expect(URLClassifier.classify(url) == .openDirect)
    }

    @Test("legitimate whole-Cyrillic host москва.com opens direct")
    func legitCyrillicHostMoskvaOpensDirect() throws {
        // москва.com — м/к/в have no clean lowercase Latin twin, so the label
        // is a real word, not a homoglyph spelling. Must stay open.
        let url = try #require(
            URL(string: "https://\u{043C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}.com/"))
        #expect(URLClassifier.classify(url) == .openDirect)
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
            ("https://exa%5Dmple.com/", "]"),
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
