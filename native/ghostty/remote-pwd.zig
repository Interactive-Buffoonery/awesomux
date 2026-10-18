//! awesoMux-only advisory OSC 7 transport. No terminal cwd mutation.
const std = @import("std");

pub const Report = struct {
    bytes: [2048]u8 = undefined,
    len: u16 = 0,

    pub fn init(raw: []const u8) Report {
        var result: Report = .{};
        if (raw.len > result.bytes.len or
            !std.unicode.utf8ValidateSlice(raw) or
            std.mem.indexOfScalar(u8, raw, 0) != null) return result;
        @memcpy(result.bytes[0..raw.len], raw);
        result.len = @intCast(raw.len);
        return result;
    }

    pub fn slice(self: *const Report) []const u8 {
        return self.bytes[0..self.len];
    }
};
