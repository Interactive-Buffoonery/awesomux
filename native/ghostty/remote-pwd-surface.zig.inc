        .awesomux_remote_pwd => |report| {
            // The surface mailbox is drained by app tick on the main thread.
            // A real local PWD is absolute and cannot collide with this tag.
            const prefix = "awesomux:remote-osc7:";
            var buffer: [prefix.len + 2048 + 1]u8 = undefined;
            @memcpy(buffer[0..prefix.len], prefix);
            const end = prefix.len + report.len;
            @memcpy(buffer[prefix.len..end], report.slice());
            buffer[end] = 0;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .pwd,
                .{ .pwd = buffer[0..end :0] },
            );
        },
