# Branch HEAD watcher integration check

Run `python3 script/branch-head-watch-e2e/run.py` on macOS.

This compiles the current production `PathInfo`, `DocumentFileWatcher`, and
`TerminalPathBarView.watchHead` method and ordinary read/commit/chip-guard sections into a disposable executable. View state
is represented by reference storage; session input contains only the unchanged
cwd. The fixture replaces model construction with the production PathInfo read. Test-only probes observe watcher teardown and hold callback delivery for the reverse-reader ordering check.
It creates isolated Git repositories with hooks and user/system config disabled.

The check covers ordinary same-cwd external checkout with an unchanged title,
linked-worktree `.git` files, detached HEAD, repeated atomic HEAD replacement,
chip clearing, both reader completion orders, ordinary-read ABA, identical-HEAD chip validity, and cancellation before a held read completes. The existing branch-menu snapshot check remains
separate. Neither check mounts SwiftUI or proves native rendering/accessibility.

The reused watcher retries a temporarily absent HEAD for about 200 ms. A HEAD
removed for longer needs an existing title/focus/cwd resolve to recover; this
change adds no periodic recovery or network lookup.
