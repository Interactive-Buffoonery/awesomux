
// Failure model: semanticPrompt must not turn absent/malformed status into
// success or out-of-range status into failure before the C boundary.
test "awesomux-command-status OSC 133 parser through completion C export" {
    const status = @import("../terminal/awesomux_command_status.zig");
    const cases = [_]struct { input: []const u8, expected: i16 }{
        .{ .input = "133;D", .expected = -1 },
        .{ .input = "133;D;0", .expected = 0 },
        .{ .input = "133;D;1", .expected = 1 },
        .{ .input = "133;D;7", .expected = 7 },
        .{ .input = "133;D;255", .expected = 255 },
        .{ .input = "133;D;256", .expected = -1 },
        .{ .input = "133;D;-1", .expected = -1 },
        .{ .input = "133;D;invalid", .expected = -1 },
        .{ .input = "133;D;2147483648", .expected = -1 },
    };
    for (cases) |case| {
        var parser: terminal.osc.Parser = .init(null);
        for ("133;C") |ch| parser.next(ch);
        try std.testing.expectEqual(
            terminal.osc.Command.SemanticPrompt.Action.end_input_start_output,
            parser.end(null).?.semantic_prompt.action,
        );
        parser = .init(null);
        for (case.input) |ch| parser.next(ch);
        const command = parser.end(null).?.semantic_prompt;
        try std.testing.expectEqual(terminal.osc.Command.SemanticPrompt.Action.end_command, command.action);
        const message: apprt.surface.Message = .{ .stop_command = status.exitCode(command) };
        const exported = (CommandFinished{
            .exit_code = message.stop_command,
            .duration = .{ .duration = 40_000_000_000 },
        }).cval();
        try std.testing.expectEqual(case.expected, exported.exit_code);
        try std.testing.expectEqual(@as(u64, 40_000_000_000), exported.duration);
    }
}
