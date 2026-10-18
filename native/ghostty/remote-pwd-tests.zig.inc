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
