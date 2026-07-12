import Testing
@testable import awesoMux

@Suite("GhosttyDragDropContent")
struct GhosttyDragDropContentTests {
    @Test("explicit URL string wins over everything else and is escaped as one token")
    func explicitURLWins() {
        let payload = GhosttyDragPayload(
            explicitURLString: "https://example.com/a b",
            fileURLPaths: ["/tmp/other file.txt"],
            plainString: "plain text"
        )

        #expect(GhosttyDragDropContent.text(from: payload) == "https://example.com/a\\ b")
    }

    @Test("file URL paths are escaped individually and space-joined")
    func fileURLPathsEscapedAndJoined() {
        let payload = GhosttyDragPayload(
            explicitURLString: nil,
            fileURLPaths: ["/tmp/one two.txt", "/tmp/three.txt"],
            plainString: "plain text"
        )

        #expect(
            GhosttyDragDropContent.text(from: payload)
                == "/tmp/one\\ two.txt /tmp/three.txt"
        )
    }

    @Test("plain string falls back and is inserted unescaped")
    func plainStringUnescaped() {
        let payload = GhosttyDragPayload(
            explicitURLString: nil,
            fileURLPaths: [],
            plainString: "echo hello; rm -rf /"
        )

        #expect(GhosttyDragDropContent.text(from: payload) == "echo hello; rm -rf /")
    }

    @Test("nothing usable on the pasteboard returns nil")
    func nilWhenNothingUsable() {
        let payload = GhosttyDragPayload(
            explicitURLString: nil,
            fileURLPaths: [],
            plainString: nil
        )

        #expect(GhosttyDragDropContent.text(from: payload) == nil)
    }

    @Test("empty file URL list falls through to plain string")
    func emptyFileURLListFallsThrough() {
        let payload = GhosttyDragPayload(
            explicitURLString: nil,
            fileURLPaths: [],
            plainString: "fallback"
        )

        #expect(GhosttyDragDropContent.text(from: payload) == "fallback")
    }

    @Test("file URL path with shell metacharacters is escaped, not just space")
    func fileURLPathWithShellMetacharactersEscaped() {
        let payload = GhosttyDragPayload(
            explicitURLString: nil,
            fileURLPaths: ["/tmp/weird$name.txt"],
            plainString: "plain text"
        )

        #expect(
            GhosttyDragDropContent.text(from: payload)
                == "/tmp/weird\\$name.txt"
        )
    }
}

@Suite("TerminalInsertionEscaping")
struct TerminalInsertionEscapingTests {
    @Test("escapes shell metacharacters and whitespace")
    func escapesMetacharacters() {
        #expect(TerminalInsertionEscaping.escape("a b") == "a\\ b")
        #expect(TerminalInsertionEscaping.escape("a(b)") == "a\\(b\\)")
        #expect(TerminalInsertionEscaping.escape("a&b|c") == "a\\&b\\|c")
        #expect(TerminalInsertionEscaping.escape("it's") == "it\\'s")
    }

    @Test("ANSI-C-quotes newlines instead of backslash-escaping them")
    func escapesNewlines() {
        // A backslash directly before a raw newline is a shell line
        // *continuation*, not an escaped literal newline -- it would eat
        // the newline and collapse "a\nb" into the single line "ab",
        // silently referencing the wrong file. `$'\n'` is a self-contained
        // ANSI-C-quoted literal that bash/zsh concatenate correctly with
        // the backslash-escaped text on either side, so the final token
        // still parses as one argument containing the real newline byte.
        #expect(TerminalInsertionEscaping.escape("a\nb") == "a$'\\n'b")
        #expect(TerminalInsertionEscaping.escape("a\rb") == "a$'\\r'b")
    }

    @Test("leaves already-safe strings untouched")
    func leavesSafeStringsUntouched() {
        #expect(TerminalInsertionEscaping.escape("plainpath123") == "plainpath123")
    }

    @Test("escapes dollar sign to block variable expansion")
    func escapesDollarSign() {
        #expect(TerminalInsertionEscaping.escape("price$5") == "price\\$5")
        #expect(TerminalInsertionEscaping.escape("$HOME/file") == "\\$HOME/file")
    }

    @Test("escapes backtick to block command substitution")
    func escapesBacktick() {
        #expect(TerminalInsertionEscaping.escape("run`whoami`") == "run\\`whoami\\`")
    }

    @Test("escapes double quote to prevent premature quoting")
    func escapesDoubleQuote() {
        #expect(TerminalInsertionEscaping.escape("say\"hi\"") == "say\\\"hi\\\"")
    }

    @Test("prefixes a leading dash with ./ to block option injection")
    func prefixesLeadingDashWithRelativePathMarker() {
        // A file named "-rf" dropped after a typed command stem like "rm "
        // would otherwise ride through as a bare flag-shaped argument.
        #expect(TerminalInsertionEscaping.escape("-rf") == "./-rf")
        #expect(TerminalInsertionEscaping.escape("--force") == "./--force")
    }

    @Test("does not prefix a dash that isn't leading")
    func doesNotPrefixNonLeadingDash() {
        #expect(TerminalInsertionEscaping.escape("a-b") == "a-b")
    }
}
