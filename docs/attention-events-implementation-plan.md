# INT-1202: recent agent alerts

Issue: https://linear.app/interactive-buffoonery/issue/INT-1202/let-connected-assistants-check-recent-agent-alerts

## Behavior

Record attention changes synchronously in SessionStore. Retain the latest 512
changes in memory, including separate raised and resolved records sharing an
attention ID. Track native attention reasons and waiting/error states. Never
change unread counts, selection, or acknowledgement from a read.

Use existing status grants. Persistent scopes filter the identity recorded with
the event; exact-target scopes additionally require a matching live target and return `stale_target`
when that incarnation has ended.
Each client holds its own opaque cursor. Bind cursors to the app instance,
connection, and grant revisions. Keep global event positions encrypted so a
client cannot infer activity outside its scope from cursor counters.

A first request reads retained history. Requests use a positive limit capped at
100 events. An invalid cursor fails; a cursor from a previous instance, a changed
grant, or an evicted position returns an explicit recovery status, no events,
and a fresh cursor at the current end. The client can call list_agents for its
authorized current state and then resume checking events. There is no durable
history or background monitoring in this issue.

## Failure cases to verify before implementation

- Attention appears and clears between requests; both changes must survive.
- Repeated unchanged signals must not duplicate alerts.
- Reading a page must not change unread, selection, or native attention.
- Pagination must not skip a resolution or an authorized event after hidden ones.
- Two clients must read independently; a cursor cannot transfer between them.
- Persistent pane/workspace scopes must exclude unrelated history.
- An exact-target grant must stop exposing events after lifecycle replacement.
- Invalid, altered, future, and foreign cursors must fail explicitly.
- Retention overflow, restart, and changed grants must require current-state recovery.
- Revocation/global disable before and during a response must disclose no events.
- Closed/moved/replaced panes must resolve the prior alert under its original identity.
- Event history must remain bounded under repeated attention transitions.
- Invalid helper flags and wire arguments must fail without enabling other operations.

## Verification

Extend the existing socket/store/helper E2E executable, with labeled provider
fixtures and attention-report.json plus representative event pages. Run the full
preflight separately. Native real-agent and phone acceptance are separate from
fixture proof. Publication requires Sarah's approval of the resulting change.
