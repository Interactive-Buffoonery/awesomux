import Foundation
import Testing
@testable import awesoMux

@Suite("MarkdownLinkRouting")
struct MarkdownLinkRoutingTests {

    // MARK: - .document route

    @Test("local .md file → .document route")
    func localMarkdownRoute() {
        let url = URL(fileURLWithPath: "/Users/example/notes/README.md")
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .document(url))
    }

    @Test("local .markdown file → .document route")
    func localMarkdownExtensionRoute() {
        let url = URL(fileURLWithPath: "/tmp/CHANGELOG.markdown")
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .document(url))
    }

    @Test("file:// URL string for .md → .document route")
    func fileURLStringMarkdownRoute() {
        let url = URL(string: "file:///home/user/doc.md")!
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .document(url))
    }

    @Test("file:// markdown with line suffix routes to stripped document URL")
    func fileURLStringMarkdownRouteStripsLineSuffix() {
        let url = URL(string: "file:///home/user/doc.md:12")!
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .document(URL(fileURLWithPath: "/home/user/doc.md")))
    }

    // MARK: - .external route

    @Test("https URL → .external route")
    func httpsExternalRoute() {
        let url = URL(string: "https://example.com/page")!
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .external(url))
    }

    @Test("http URL → .external route")
    func httpExternalRoute() {
        let url = URL(string: "http://example.com/docs")!
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .external(url))
    }

    @Test("local non-markdown file → .external route (security boundary)")
    func localNonMarkdownIsExternal() {
        // A .sh script must NOT route to document pane; it should hit .external
        // (and the URLClassifier will then reject it as a disallowed scheme /
        // non-document file). This is the primary OSC-8-arbitrary-exec boundary.
        let url = URL(fileURLWithPath: "/tmp/evil.sh")
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .external(url))
    }

    @Test("https URL with .md path segment → .external route (not a local file)")
    func remoteMarkdownURLIsExternal() {
        let url = URL(string: "https://raw.githubusercontent.com/foo/bar/README.md")!
        let route = MarkdownLinkRouting.route(url)
        #expect(route == .external(url))
    }

    // MARK: - Route.Equatable

    @Test("same URL produces equal routes")
    func routeEquality() {
        let url = URL(fileURLWithPath: "/tmp/doc.md")
        #expect(MarkdownLinkRouting.route(url) == MarkdownLinkRouting.route(url))
    }

    @Test("document and external routes for different URLs are not equal")
    func routeInequality() {
        let mdURL = URL(fileURLWithPath: "/tmp/doc.md")
        let webURL = URL(string: "https://example.com")!
        #expect(MarkdownLinkRouting.route(mdURL) != MarkdownLinkRouting.route(webURL))
    }
}
