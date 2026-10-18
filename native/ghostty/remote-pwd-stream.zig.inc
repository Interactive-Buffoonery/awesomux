        // Preserve the complete report before upstream rejects nonlocal hosts.
        // Invalid or oversize reports send an empty invalidation, never a prefix.
        self.surfaceMessageWriter(.{ .awesomux_remote_pwd = .capture(url, &self.renderer_state.awesomux_remote_pwd_generation) });
