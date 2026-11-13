# Branch menu snapshot regression

Run `python3 script/branch-menu-snapshot-e2e/run.py` from any directory on macOS with Swift installed.

The check compiles the current production `toggleBranchMenu`, `PathInfo` HEAD resolver, loading state and menu filtering into a temporary fixture. It holds enumeration, performs a real Git checkout, refreshes the model at the same cwd, and releases the real branch list. The pinned display must remain paired with the raw branch captured at activation. It runs with both a plain branch name (to detect lost raw deduplication) and a bidi override (to require sanitized display and safe clickable rows).

The fixture replaces mounted SwiftUI state with main-actor reference storage and replaces the runner with a held continuation. It does not launch the app or prove native rendering, dismissal callbacks, focus, accessibility or VoiceOver. Existing `BranchMenuLoadingTests` cover token ownership and stale completion rejection. Temporary repositories contain no user data. The runner clears inherited Git environment variables and disables global/system config, hooks and templates so fixture commands cannot be redirected by the caller’s Git environment.
