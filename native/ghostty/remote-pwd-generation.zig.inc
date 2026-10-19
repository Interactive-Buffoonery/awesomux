// Independent of the renderer mutex: main-thread barrier, IO-thread capture.
awesomux_remote_pwd_generation: std.atomic.Value(u64) = .init(1),
