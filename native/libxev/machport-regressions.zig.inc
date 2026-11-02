fn awesomux_machport_messages(nested: bool) !void {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const testing = std.testing;
    var loop = try Loop.init(.{});
    defer loop.deinit();
    const mach_self = posix.system.mach_task_self();
    var port: posix.system.mach_port_name_t = undefined;
    try testing.expectEqual(darwin.KernE.SUCCESS, darwin.getKernError(
        posix.system.mach_port_allocate(mach_self, posix.system.MACH.PORT.RIGHT.RECEIVE, &port),
    ));
    defer _ = posix.system.mach_port_deallocate(mach_self, port);
    const fds = try make_pipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    var dummy: Completion = .{
        .op = .{ .read = .{ .fd = fds[0], .buffer = .{ .array = undefined } } },
        .callback = (struct {
            fn callback(_: ?*anyopaque, _: *Loop, _: *Completion, r: Result) CallbackAction {
                _ = r.read catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    const State = struct {
        nested: bool,
        dummy: *Completion,
        count: usize = 0,
        ids: [3]i32 = @splat(0),
    };
    var state: State = .{ .nested = nested, .dummy = &dummy };
    var completion: Completion = .{
        .op = .{ .machport = .{ .port = port, .buffer = .{ .array = undefined } } },
        .userdata = &state,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *Loop, c: *Completion, r: Result) CallbackAction {
                _ = r.machport catch unreachable;
                const s: *State = @ptrCast(@alignCast(ud.?));
                // Submit other work while the current message is still in use.
                if (s.nested and s.count == 0) {
                    l.add(s.dummy);
                    l.submit() catch unreachable;
                }
                const message: *align(1) const darwin.mach_msg_header_t = @ptrCast(&c.op.machport.buffer.array);
                if (s.count < s.ids.len) s.ids[s.count] = message.msgh_id;
                s.count += 1;
                return if (s.count < s.ids.len) .rearm else .disarm;
            }
        }).callback,
    };
    for ([_]i32{ 11, 22, 33 }) |id| {
        var message: darwin.mach_msg_header_t = .{
            .msgh_bits = @intFromEnum(posix.system.MACH.MSG.TYPE.MAKE_SEND_ONCE),
            .msgh_size = @sizeOf(darwin.mach_msg_header_t),
            .msgh_remote_port = port,
            .msgh_local_port = darwin.MACH_PORT_NULL,
            .msgh_voucher_port = darwin.MACH_PORT_NULL,
            .msgh_id = id,
        };
        try testing.expectEqual(darwin.MachMsgE.SUCCESS, darwin.getMachMsgError(darwin.mach_msg(
            &message, darwin.MACH_SEND_MSG, message.msgh_size, 0,
            darwin.MACH_PORT_NULL, darwin.MACH_MSG_TIMEOUT_NONE, darwin.MACH_PORT_NULL,
        )));
    }
    loop.add(&completion);
    try loop.submit();
    if (!nested) {
        loop.add(&dummy);
        try loop.submit();
    }
    var ticks: usize = 0;
    while (!loop.done() and ticks < 16) : (ticks += 1) try loop.run(.no_wait);
    try testing.expectEqual(@as(usize, 3), state.count);
    try testing.expectEqualSlices(i32, &.{ 11, 22, 33 }, &state.ids);
    try testing.expectEqual(@as(usize, 0), loop.active);
}

test "awesomux-machport: repeated submit preserves message payloads" {
    try awesomux_machport_messages(false);
}

test "awesomux-machport: nested submit preserves the current message" {
    try awesomux_machport_messages(true);
}
