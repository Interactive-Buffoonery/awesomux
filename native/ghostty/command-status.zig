const std = @import("std");
const osc = @import("osc.zig");

/// OSC 133 may omit status; malformed or non-byte values are also unknown.
pub fn exitCode(command: osc.Command.SemanticPrompt) ?u8 {
    const raw = command.readOption(.exit_code) orelse return null;
    return std.math.cast(u8, raw);
}
