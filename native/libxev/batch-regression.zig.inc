test "kqueue: submit must not consume readiness reported to a later batch" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;

    // Sized against `submit`'s changelist rather than a round number. One
    // batch is the whole precondition: a submission queue that fits in it
    // costs a single kevent, and nothing can be reported to a single call
    // twice. Past it the queue is drained in two, and every completion the
    // first batch registered is a candidate to come back as ready in the
    // second batch's reply — already completed, already linked.
    const n = 256 + 44;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    var fds: [n][2]posix.fd_t = undefined;
    var opened: usize = 0;
    errdefer for (fds[0..opened]) |p| {
        xev_posix.close(p[0]);
        xev_posix.close(p[1]);
    };
    while (opened < n) : (opened += 1) fds[opened] = try xev_posix.pipe2(.{ .CLOEXEC = true });
    defer for (fds) |p| {
        xev_posix.close(p[0]);
        xev_posix.close(p[1]);
    };

    // Writes, because a fresh pipe is writable the instant it is
    // registered: every completion batch 1 submits is ready before batch 2
    // asks the kernel anything.
    var done: usize = 0;
    var cs: [n]Completion = undefined;
    for (&cs, 0..) |*c, i| {
        c.* = .{
            .op = .{ .write = .{
                .fd = fds[i][1],
                .buffer = .{ .slice = "x" },
            } },
            .userdata = &done,
            .callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l: *Loop,
                    c_inner: *Completion,
                    r: Result,
                ) CallbackAction {
                    _ = l;
                    _ = c_inner;
                    _ = r.write catch unreachable;
                    const count: *usize = @ptrCast(@alignCast(ud.?));
                    count.* += 1;
                    return .disarm;
                }
            }).callback,
        };
        loop.add(c);
    }

    // All `n` are queued against one `submit`, which is what puts a batch
    // boundary inside it. Before the fix this trips `queue.push`'s
    // `v.next == null` on the first duplicate report (issues #122, #169).
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, n), done);
}
