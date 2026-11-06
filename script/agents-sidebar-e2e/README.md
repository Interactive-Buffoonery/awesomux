# Agents sidebar scenarios

Run `./script/agents-sidebar-e2e/run.sh` with the pinned macOS toolchain.
The fixture uses the production Core module and public SessionStore APIs. It does not
launch agents, submit terminal input, decide permissions, or touch saved workspaces.

Scenarios cover pane-grain classification, conservative waiting/completion labels,
unknown notification reasons, errors versus confirmed process failures, split-pane
ownership, next-target cycling, empty/closed targets, notification-only mark-seen,
explicit reminder dismissal, moved panes, heartbeat-independent order and custom titles.
The executable fails on its first violated precondition and prints PASS lines only
after the corresponding assertions execute.

This is model/integration evidence. It does not verify native keyboard focus,
VoiceOver speech, pointer stability, real provider hook delivery, or permission UI.

Permission accounting also covers mark-seen → new notification → old permission drain,
and draining an older seen prompt while a newer prompt is still unread. The existing
WorkspaceAttentionReducer Swift Testing suite has one controlled-scheduler regression
(three action cases) because reproducing the stale-dwell window requires isolated
scheduler control; it verifies that explicit marking cannot clear a newer event.
