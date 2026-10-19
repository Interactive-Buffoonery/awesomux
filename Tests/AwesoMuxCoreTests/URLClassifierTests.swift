import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("URLClassifier")
struct URLClassifierTests {

    @Test(arguments: [
        "https://example.com/path?q=1",
        "http://example.com",
        "mailto:foo@example.com",
        "mailto:foo@example.com?subject=",
        "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}.\u{0440}\u{0444}/",
        "https://\u{65E5}\u{672C}\u{8A9E}.jp/",
        "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}-2.\u{0440}\u{0444}/",
        "https://\u{044F}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}.com/",
        "https://xn--80adxhks.com/",
        "https://\u{043E}\u{0441}\u{044C}.com/",
        "https://\u{044F}.com/",
        "https://\u{043C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}.com/",
        "mailto:foo@example.com?in-reply-to=abc",
        "HTTPS://example.com",
        "https://example.com/caf%C3%A9/menu.pdf",
        "http://localhost:3000/",
        "http://192.0.2.1/admin",
        "http://[::1]/admin",
    ])
    func opensDirect(rawURL: String) throws {
        #expect(URLClassifier.classify(try #require(URL(string: rawURL))) == .openDirect)
    }

    @Test(arguments: Self.blockedURLs)
    func blocks(rawURL: String, expected: URLClassifier.BlockReason, delimiter: String?) throws {
        let decision = URLClassifier.classify(try #require(URL(string: rawURL)))
        guard case let .blockConfirm(reason, displayHost, punycodeHost) = decision else {
            Issue.record("expected confirmation for \(rawURL)"); return
        }
        #expect(reason == expected)
        if let delimiter { #expect(displayHost?.contains(delimiter) == true) }
        if expected == .mailtoWithParameters || expected == .disallowedScheme {
            #expect(displayHost == nil)
            #expect(punycodeHost == nil)
        }
    }

    private static let blockedURLs: [(String, URLClassifier.BlockReason, String?)] = [
        ("https://p\u{0430}ypal.com/login", .nonAsciiHost, nil),
        ("https://\u{A7CA}\u{0430}.com/", .nonAsciiHost, nil),
        ("https://xn--a.com/", .nonAsciiHost, nil),
        ("https://good.xn--a.com/", .nonAsciiHost, nil),
        ("https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.com/", .nonAsciiHost, nil),
        ("https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.\u{043C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}/", .nonAsciiHost, nil),
        ("https://\u{0475}\u{0456}\u{0455}\u{0430}.com/", .nonAsciiHost, nil),
        ("https://xn--80a7ec7j.com/", .nonAsciiHost, nil),
        ("https://\u{0430}.com/", .nonAsciiHost, nil),
        ("https://\u{0441}.com/", .nonAsciiHost, nil),
        ("https://\u{0501}.com/", .nonAsciiHost, nil),
        ("https://\u{0435}.com/", .nonAsciiHost, nil),
        ("https://\u{04BB}.com/", .nonAsciiHost, nil),
        ("https://\u{0456}.com/", .nonAsciiHost, nil),
        ("https://\u{0458}.com/", .nonAsciiHost, nil),
        ("https://\u{04CF}.com/", .nonAsciiHost, nil),
        ("https://\u{043E}.com/", .nonAsciiHost, nil),
        ("https://\u{0440}.com/", .nonAsciiHost, nil),
        ("https://\u{051B}.com/", .nonAsciiHost, nil),
        ("https://\u{0455}.com/", .nonAsciiHost, nil),
        ("https://\u{0475}.com/", .nonAsciiHost, nil),
        ("https://\u{051D}.com/", .nonAsciiHost, nil),
        ("https://\u{0445}.com/", .nonAsciiHost, nil),
        ("https://\u{0443}.com/", .nonAsciiHost, nil),
        ("https://\u{0441}\u{043E}\u{0441}\u{043E}.com/", .nonAsciiHost, nil),
        ("https://\u{043E}.com/", .nonAsciiHost, nil),
        ("https://\u{0430}\u{0440}\u{0435}-2.com/", .nonAsciiHost, nil),
        ("https://\u{0410}\u{0420}\u{0420}\u{04C0}\u{0415}.com/", .nonAsciiHost, nil),
        ("mailto:victim@example.com?body=Please%20click%20here", .mailtoWithParameters, nil),
        ("mailto:foo@example.com?subject=Urgent", .mailtoWithParameters, nil),
        ("mailto:foo@example.com?cc=spy@evil.example", .mailtoWithParameters, nil),
        ("mailto:foo@example.com?bcc=spy@evil.example", .mailtoWithParameters, nil),
        ("file:///etc/passwd", .disallowedScheme, nil),
        ("javascript:alert(1)", .disallowedScheme, nil),
        ("vscode://settings/sync", .disallowedScheme, nil),
        ("https://user:pass@example.com/", .embeddedUserInfo, nil),
        ("https:///path", .missingHost, nil),
        ("https://example.com/path/\u{202E}gnp.exe", .pathHasUnsafeCodepoints, nil),
        ("https://example.com/login\u{200B}suffix", .pathHasUnsafeCodepoints, nil),
        ("mailto:?to=victim@example.com", .mailtoWithParameters, nil),
        ("mailto:foo@example.com?SUBJECT=Urgent", .mailtoWithParameters, nil),
        ("https://:secret@evil.example/", .embeddedUserInfo, nil),
        ("https://exa%0Ample.com/", .nonAsciiHost, nil),
        ("https://paypal.com%40evil.example/", .nonAsciiHost, "@"),
        ("https://exa%2Fmple.com/", .nonAsciiHost, "/"),
        ("https://exa%3Fmple.com/", .nonAsciiHost, "?"),
        ("https://exa%23mple.com/", .nonAsciiHost, "#"),
        ("https://exa%5Bmple.com/", .nonAsciiHost, "["),
        ("https://exa%5Dmple.com/", .nonAsciiHost, "]"),
        ("https://example.com/path%0Aspoof", .pathHasUnsafeCodepoints, nil),
        ("https://example.com/a\u{2028}b", .pathHasUnsafeCodepoints, nil),
        ("https://example.com/a\u{2029}b", .pathHasUnsafeCodepoints, nil),
        ("https://example.com/search?q=value\u{202E}", .pathHasUnsafeCodepoints, nil),
        ("https://example.com/page#section\u{200B}", .pathHasUnsafeCodepoints, nil),
    ]

    @Test(arguments: [
        ("https://\u{0440}aypal.com/login", nil),
        ("https://xn--aypal-58d.com/login", "xn--aypal-58d.com"),
        ("https://xn--80ak6aa92e.com/", nil),
    ])
    func confirmationHostForms(rawURL: String, expectedPunycode: String?) throws {
        let decision = URLClassifier.classify(try #require(URL(string: rawURL)))
        guard case let .blockConfirm(reason, displayHost, punycodeHost) = decision else { Issue.record("expected confirmation"); return }
        #expect(reason == .nonAsciiHost)
        #expect(displayHost?.unicodeScalars.contains(where: { $0.value > 0x7F }) == true)
        #expect(punycodeHost?.contains("xn--") == true)
        #expect(punycodeHost != displayHost)
        if let expectedPunycode { #expect(punycodeHost == expectedPunycode) }
    }

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

}
