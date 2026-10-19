//! awesoMux-only detection for delimited spaced paths and bare Markdown names.
const std = @import("std");
const oni = @import("oniguruma");
const upstream = @import("url.zig");

// Spaces need explicit boundaries so prose and adjacent links stay separate.
// shortcut: internal quotes/parentheses are excluded; extend only with balanced-path tests.
const spaced_markdown_path =
    \\(?=[\w\-.~/ %#@!$&*+;=]* )[\w.~/-][\w\-.~/ %#@!$&*+;=]*\.(?i:md|markdown)(?::[0-9]+(?::[0-9]+)?)?
;

// Match only complete tokens, using the click probe's surrounding delimiters.
// Lookarounds keep delimiters out of the native highlighted/opened range.
const bare_markdown_filename =
    \\(?<![^\s'"`;,()\[\]{}<>|])[\p{L}\p{M}\p{N}_.-]+\.(?i:md|markdown)(?::[0-9]+(?::[0-9]+)?)?(?![^\s'"`;,()\[\]{}<>|])
;

pub const regex =
    "(?:(?<=\\()" ++ spaced_markdown_path ++ "(?=\\))" ++
    "|(?<=\")" ++ spaced_markdown_path ++ "(?=\")" ++
    "|(?<=')" ++ spaced_markdown_path ++ "(?=')" ++
    "|(?<=`)" ++ spaced_markdown_path ++ "(?=`))|" ++
    upstream.regex ++ "|" ++ bare_markdown_filename;

test "awesomux-link-paths delimited spaces, bare Markdown and existing links" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Findings (12345678-case - example.com - Desktop REST browser challenge/findings.md)", .expected = "12345678-case - example.com - Desktop REST browser challenge/findings.md" },
        .{ .input = "Reply (12345678-case - example.com - Desktop REST browser challenge/reply-draft-en.md)", .expected = "12345678-case - example.com - Desktop REST browser challenge/reply-draft-en.md" },
        .{ .input = "(test folder/notes.md)", .expected = "test folder/notes.md" },
        .{ .input = "(./test folder/notes.md)", .expected = "./test folder/notes.md" },
        .{ .input = "(../test folder/notes.md)", .expected = "../test folder/notes.md" },
        .{ .input = "(/tmp/test folder/notes.md)", .expected = "/tmp/test folder/notes.md" },
        .{ .input = "(~/test folder/notes.md)", .expected = "~/test folder/notes.md" },
        .{ .input = "(notes final.md)", .expected = "notes final.md" },
        .{ .input = "(test  folder/notes.MARKDOWN:12:3)", .expected = "test  folder/notes.MARKDOWN:12:3" },
        .{ .input = "\"test folder/notes.md\"", .expected = "test folder/notes.md" },
        .{ .input = "'test folder/notes.md'", .expected = "test folder/notes.md" },
        .{ .input = "`test folder/notes.md`", .expected = "test folder/notes.md" },
        .{ .input = "See (test folder/notes.md), then (other folder/next.md).", .expected = "test folder/notes.md" },
        .{ .input = "[notes](test folder/notes.md)", .expected = "test folder/notes.md" },
        .{ .input = "(test folder/notes.md) https://example.com", .expected = "test folder/notes.md" },
        .{ .input = "(https://example.com/notes.md)", .expected = "https://example.com/notes.md" },
        .{ .input = "docs/notes.md more text", .expected = "docs/notes.md" },
        .{ .input = "(docs/notes.md)", .expected = "docs/notes.md" },
        .{ .input = "(test folder/notes.md.bak)", .expected = "folder/notes.md.bak" },
        .{ .input = "test folder/notes.md", .expected = "folder/notes.md" },
        .{ .input = "(test folder/notes.md please)", .expected = "folder/notes.md" },
        .{ .input = "(test folder/notes.md]", .expected = "folder/notes.md" },
        .{ .input = "(test\nfolder/notes.md)", .expected = "folder/notes.md" },
        .{ .input = "(test\tfolder/notes.md)", .expected = "folder/notes.md" },
        .{ .input = "README.md", .expected = "README.md" },
        .{ .input = "See README.MD now", .expected = "README.MD" },
        .{ .input = "[release.notes.MarkDown:12:3]", .expected = "release.notes.MarkDown:12:3" },
        .{ .input = "'README.md:12'", .expected = "README.md:12" },
        .{ .input = "\"README.md\"", .expected = "README.md" },
        .{ .input = "`README.md`", .expected = "README.md" },
        .{ .input = "(README.md)", .expected = "README.md" },
        .{ .input = "{README.md}", .expected = "README.md" },
        .{ .input = "<README.md>", .expected = "README.md" },
        .{ .input = "|README.md|", .expected = "README.md" },
        .{ .input = "\tREADME.md; next", .expected = "README.md" },
        .{ .input = "README.md,next", .expected = "README.md" },
        .{ .input = "café.md", .expected = "café.md" },
        .{ .input = "https://example.com/README.md", .expected = "https://example.com/README.md" },
        .{ .input = "file:///tmp/README.md", .expected = "file:///tmp/README.md" },
        .{ .input = "README.md/next", .expected = "README.md/next" },
        .{ .input = "./README.md", .expected = "./README.md" },
        .{ .input = "docs/README.md:12", .expected = "docs/README.md:12" },
    };
    for (cases) |case| {
        var region = try re.search(case.input, .{});
        defer region.deinit();
        try std.testing.expect(region.count() > 0);
        const matched = case.input[@intCast(region.starts()[0])..@intCast(region.ends()[0])];
        try std.testing.expectEqualStrings(case.expected, matched);
    }
    const no_match_cases = [_][]const u8{
        "user@README.md", "README.md@example.com", "example.com",
        "README.md.com", "README.md.bak", "README.markdown.bak",
        "README.md:abc", "README.md:12:abc", "README.md:12:3:4",
        "$README.md", "README.md$", "#README.md", "README.md#anchor",
        "%README.md", "README.md%20", "+README.md", "README.md+",
        "=README.md", "README.md=", "!README.md", "README.md!",
        "?README.md", "README.md?", "@README.md", "README.md@",
        "~README.md", "README.md~", "README.md.", "README.md:",
        "\\README.md", "README.md\\",
    };
    for (no_match_cases) |input| {
        if (re.search(input, .{})) |result| {
            var region = result;
            region.deinit();
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(error.Mismatch, err);
        }
    }
}
