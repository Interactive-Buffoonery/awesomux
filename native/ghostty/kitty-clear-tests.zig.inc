test "awesomux-kitty-clear redraw after prompt clear" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 40, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000;
    t.height_px = 800;
    var state: State = .empty;
    defer state.deinit(alloc);
    const s = &t.screens.active.kitty_images;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1, .format = .rgba, .data = .{ .complete = try alloc.dupe(u8, "rgba") } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*) },
        .columns = 30,
        .rows = 15,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 20 });
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);
    t.setCursorPos(20, 1);
    try t.semanticPrompt(.init(.prompt_start));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    t.setCursorPos(1, 1);
    t.eraseDisplay(.complete, false);
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 20 });
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    t.eraseDisplay(.scrollback, false);
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 20 });
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
}

test "awesomux-kitty-clear bounded history preserves retained and active images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    for ([_]usize{ 6, 600 }) |lines| {
        var t = try terminal.Terminal.init(io, alloc, .{ .rows = 4, .cols = 80 });
        defer t.deinit(alloc);
        t.width_px = 800;
        t.height_px = 80;
        for (0..lines) |_| {
            try t.printString("line");
            t.carriageReturn();
            try t.linefeed();
        }
        const s = &t.screens.active.kitty_images;
        const points = [_]terminal.point.Point{
            .{ .history = .{ .y = 0 } },
            .{ .active = .{ .y = 0 } },
            .{ .history = .{ .y = 2 } },
        };
        for (points, 1..) |pt, id| {
            try s.addImage(io, alloc, t.screens.active, .{ .id = @intCast(id), .width = 1, .height = 1 });
            try s.addPlacement(io, alloc, t.screens.active, @intCast(id), 1, .{
                .location = .{ .pin = try t.screens.active.pages.trackPin(t.screens.active.pages.pin(pt).?) },
                .columns = 1,
                .rows = 1,
            });
        }
        s.dirty = false;
        t.screens.active.eraseHistory(.{ .history = .{ .y = 0 } });
        try testing.expect(s.dirty);
        try testing.expectEqual(@as(usize, 2), s.placements.count());
        var keys = s.placements.keyIterator();
        while (keys.next()) |key| try testing.expect(key.image_id != 1);
        t.eraseDisplay(.scrollback, false);
        try testing.expectEqual(@as(usize, 1), s.placements.count());
        keys = s.placements.keyIterator();
        try testing.expectEqual(@as(u32, 2), keys.next().?.image_id);
        const generation = s.generation;
        s.dirty = false;
        t.eraseDisplay(.scrollback, false);
        try testing.expectEqual(generation, s.generation);
        try testing.expect(!s.dirty);
        try testing.expect(s.imageById(1) != null);
        try testing.expect(s.imageById(3) != null);
        t.eraseDisplay(.complete, false);
        try testing.expectEqual(@as(usize, 0), s.placements.count());
    }
}

test "awesomux-kitty-clear no-scrollback resize removes erased anchors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    for ([_]bool{ false, true }) |alternate| {
        var t = try terminal.Terminal.init(io, alloc, .{ .rows = 6, .cols = 80 });
        defer t.deinit(alloc);
        if (alternate) {
            _ = try t.switchScreen(.alternate);
        } else {
            t.setScrollbackMaxBytes(0);
        }
        const s = &t.screens.active.kitty_images;
        try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
        try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
            .location = .{ .pin = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*) },
            .columns = 1,
            .rows = 1,
        });
        for (1..7) |row| {
            t.setCursorPos(row, 1);
            try t.printString("line");
        }
        try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
        try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
            .location = .{ .pin = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*) },
            .columns = 1,
            .rows = 1,
        });
        try t.resize(alloc, .{ .cols = 80, .rows = 4 });
        try testing.expectEqual(@as(usize, 1), s.placements.count());
        var keys = s.placements.keyIterator();
        try testing.expectEqual(@as(u32, 2), keys.next().?.image_id);
    }
}
