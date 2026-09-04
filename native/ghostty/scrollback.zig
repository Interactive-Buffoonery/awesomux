// MIT licensed, like awesoMux and Ghostty. Built inside the pinned Ghostty tree.
const std = @import("std");
const Screen = @import("Screen.zig");
const Page = @import("page.zig").Page;
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;

pub const Limits = struct {
    rows: usize,
    cells: usize,
    page_bytes: usize,
};

pub const Error = error{TooLarge};

/// The caller must hold the renderer mutex for both admission and extraction.
/// Page metadata is available without decompressing history. Bound that work
/// too: a small number of cells can have unusually large grapheme storage.
pub fn read(screen: *Screen, limits: Limits, buffer: []u8) Error!usize {
    if (screen.pages.total_rows > limits.rows) return error.TooLarge;
    var cells_left = limits.cells;
    var bytes_left = limits.page_bytes;
    var rows_left = limits.rows;
    var node = screen.pages.pages.first;
    while (node) |n| : (node = n.next) {
        const rows: usize = n.rows();
        const cols: usize = n.cols();
        if (rows == 0 or cols == 0 or rows > rows_left) return error.TooLarge;
        rows_left -= rows;
        if (rows > cells_left / cols) return error.TooLarge;
        cells_left -= rows * cols;
        const page_bytes = Page.layout(n.capacity()).total_size;
        if (page_bytes > bytes_left) return error.TooLarge;
        bytes_left -= page_bytes;
    }

    // A fixed writer fails at the byte boundary; it never allocates a full
    // native string and never returns a partial history as a successful dump.
    var writer: std.Io.Writer = .fixed(buffer);
    const formatter: ScreenFormatter = .init(screen, .{
        .emit = .plain,
        .unwrap = true,
        .trim = false,
    });
    formatter.format(&writer) catch return error.TooLarge;
    return writer.end;
}

const testing = std.testing;
const test_limits: Limits = .{ .rows = 8192, .cells = 262144, .page_bytes = 16 * 1024 * 1024 };

test "awesomux-scrollback: stable small history matches the existing plain-text read" {
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 64 * 1024 * 1024 });
    defer screen.deinit();
    try screen.testWriteString("hello\nworld\u{0}\u{e9}");
    var buffer: [1024]u8 = undefined;
    const count = try read(&screen, test_limits, &buffer);
    const selection = @import("Selection.zig").init(screen.pages.getTopLeft(.screen), screen.pages.getBottomRight(.screen).?, false);
    const expected = try screen.selectionString(testing.allocator, .{ .sel = selection, .trim = false });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, buffer[0..count]);
}

test "awesomux-scrollback: unchanged rendered rows cannot admit oversized live history" {
    var terminal = try @import("Terminal.zig").init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 64 * 1024 * 1024 });
    defer terminal.deinit(testing.allocator);
    const cached_rows = terminal.screens.active.pages.total_rows;
    terminal.modes.set(.synchronized_output, true);
    for (0..4000) |_| try terminal.screens.active.testWriteString("ordinary ASCII output\n");
    try testing.expect(terminal.modes.get(.synchronized_output));
    try testing.expect(cached_rows * 80 < test_limits.cells);
    try testing.expect(terminal.screens.active.pages.total_rows * 80 > test_limits.cells);
    var buffer = [_]u8{0xa5} ** 32;
    try testing.expectError(error.TooLarge, read(terminal.screens.active, test_limits, &buffer));
    // Rejection happens before extraction touches even one output byte.
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 32), &buffer);
}

test "awesomux-scrollback: exact byte capacity succeeds and one byte less rejects" {
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    try screen.testWriteString("1234567890");
    var buffer: [32]u8 = undefined;
    const count = try read(&screen, test_limits, &buffer);
    try testing.expect(count > 0);
    try testing.expectEqual(count, try read(&screen, test_limits, buffer[0..count]));
    try testing.expectError(error.TooLarge, read(&screen, test_limits, buffer[0 .. count - 1]));
}

test "awesomux-scrollback: grapheme bytes are bounded independently of cell count" {
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    try screen.testWriteString("a");
    for (0..100) |_| try screen.testWriteString("\u{0301}");
    var buffer: [32]u8 = undefined;
    try testing.expectError(error.TooLarge, read(&screen, test_limits, &buffer));
}

test "awesomux-scrollback: page memory and row limits reject before formatting" {
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    var buffer = [_]u8{0xa5} ** 32;
    var limits = test_limits;
    limits.page_bytes = 0;
    try testing.expectError(error.TooLarge, read(&screen, limits, &buffer));
    limits = test_limits;
    limits.rows = 2;
    try testing.expectError(error.TooLarge, read(&screen, limits, &buffer));
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 32), &buffer);
}

test "awesomux-scrollback: compressed history is rejected without restoring its pages" {
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 64 * 1024 * 1024 });
    defer screen.deinit();
    while (screen.pages.pages.first == screen.pages.getTopLeft(.active).node) {
        try screen.testWriteString("history\n");
    }
    if (screen.pages.compress(.full) == .unsupported) return error.SkipZigTest;
    const first = screen.pages.pages.first.?;
    try testing.expectEqual(.compressed, first.storage());
    var limits = test_limits;
    limits.page_bytes = 0;
    var buffer: [16384]u8 = undefined;
    try testing.expectError(error.TooLarge, read(&screen, limits, &buffer));
    try testing.expectEqual(.compressed, first.storage());
    _ = try read(&screen, test_limits, &buffer);
    try testing.expectEqual(.resident, first.storage());
}
