    /// Main-thread-only setter; the IO reader copies this before enqueueing.
    export fn awesomux_surface_set_remote_pwd_generation(surface: *Surface, generation: u64) void {
        surface.core_surface.renderer_state.awesomux_remote_pwd_generation.store(generation, .release);
    }
