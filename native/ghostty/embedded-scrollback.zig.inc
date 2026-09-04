    /// awesoMux-only bounded whole-history read. No viewport metadata or native
    /// string allocation is needed; the host owns the fixed output buffer.
    export fn awesomux_surface_read_scrollback(
        surface: *Surface,
        maximum_rows: usize,
        maximum_cells: usize,
        maximum_page_bytes: usize,
        buffer: [*]u8,
        capacity: usize,
        written: *usize,
    ) c_int {
        written.* = 0;
        const state = &surface.core_surface.renderer_state;
        state.mutex.lockUncancelable(global.io());
        defer state.mutex.unlock(global.io());
        written.* = @import("../terminal/awesomux_scrollback.zig").read(
            state.terminal.screens.active,
            .{ .rows = maximum_rows, .cells = maximum_cells, .page_bytes = maximum_page_bytes },
            buffer[0..capacity],
        ) catch return 1;
        return 0;
    }

