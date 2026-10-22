    /// Remove placements before erased history can relocate their tracked pins.
    pub fn eraseHistory(
        self: *ImageStorage,
        io: std.Io,
        s: *terminal.Screen,
        bottom: ?point.Point,
    ) void {
        const before = self.placements.count();
        if (before == 0) return;
        var rows = s.pages.pageIterator(.right_down, .{ .history = .{} }, bottom);
        while (rows.next()) |chunk| {
            var placements = self.placements.iterator();
            while (placements.next()) |entry| {
                const pin = switch (entry.value_ptr.location) {
                    .pin => |pin| pin,
                    .virtual, .relative => continue,
                };
                if (pin.node == chunk.node and pin.y >= chunk.start and pin.y < chunk.end) {
                    self.removePlacement(s, entry);
                }
            }
        }
        if (self.placements.count() != before) {
            _ = self.removeOrphans(s, null);
            self.markMutated(io);
        }
    }
