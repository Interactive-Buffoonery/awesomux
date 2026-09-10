# vendor/

Third-party code lives here, all MIT/Apache-2.0/BSD/permissive only. Never anything GPL.

## Dependencies

- `vendor/ghostty/` — git submodule of `ghostty-org/ghostty` (MIT), pinned to `44f2a44df7e8c4a0c6df3f7d872ef3d7ead88e51` (untagged `origin/main`, post-`v1.3.1`; see docs/ghostty-integration.md for pin provenance).

The initial plan is to build Ghostty's Darwin `GhosttyKit.xcframework` from the
submodule with [`../script/build_ghostty_xcframework.sh`](../script/build_ghostty_xcframework.sh).
See [`../docs/ghostty-integration.md`](../docs/ghostty-integration.md).

## Rules

- Submodules pinned to a tag or specific commit, not `main`.
- License of each dep documented in this README before it's added.
- No GPL. Period. Reading GPL'd source while writing awesoMux code is a GPL contamination risk.
