test "awesomux-remote-pwd bounded complete reports" {
    const testing = std.testing;
    const valid = Report.init("file://remote/tmp");
    try testing.expectEqualStrings("file://remote/tmp", valid.slice());
    const exact = Report.init(&([_]u8{'a'} ** 2048));
    try testing.expectEqual(@as(usize, 2048), exact.slice().len);
    try testing.expectEqual(@as(usize, 0), Report.init(&([_]u8{'a'} ** 2049)).slice().len);
    try testing.expectEqual(@as(usize, 0), Report.init("file://remote/\xff").slice().len);
    try testing.expectEqual(@as(usize, 0), Report.init("file://remote/a\x00b").slice().len);
    try testing.expectEqual(@as(usize, 0), Report.init("").slice().len);
    try testing.expectEqualStrings("file://remote/é", Report.init("file://remote/é").slice());
}

test "awesomux-remote-pwd captures generation before queue delivery" {
    const testing = std.testing;
    var generation = std.atomic.Value(u64).init(7);
    const queued = Report.capture("file://remote/old", &generation);
    generation.store(8, .release);
    const fresh = Report.capture("file://remote/new", &generation);
    try testing.expectEqual(@as(u64, 7), queued.generation);
    try testing.expectEqual(@as(u64, 8), fresh.generation);
    generation.store(0, .release);
    try testing.expectEqual(@as(u64, 0), Report.capture("file://remote/disabled", &generation).generation);
    try testing.expectEqual(@as(u64, 0), Report.capture("\xff", &generation).generation);
}
