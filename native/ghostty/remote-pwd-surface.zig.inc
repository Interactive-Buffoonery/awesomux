        .awesomux_remote_pwd => |report| {
            // The surface mailbox is drained by app tick on the main thread.
            // A real local PWD is absolute and cannot collide with this tag.
            const prefix = "awesomux:remote-osc7:";
            var buffer: [prefix.len + 20 + 1 + 2048 + 1]u8 = undefined;
            const envelope = try std.fmt.bufPrintZ(&buffer, "{s}{d}:{s}", .{
                prefix, report.generation, report.slice(),
            });
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .pwd,
                .{ .pwd = envelope },
            );
        },
