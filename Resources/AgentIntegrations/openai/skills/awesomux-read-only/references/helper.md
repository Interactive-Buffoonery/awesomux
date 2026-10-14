# Local helper reference

## Setup

Run the intended awesoMux build. In **Settings → Agents → Outside app access**,
add a dedicated connection, review its status scope, and enable global access.
Use **Copy Setup Command** to obtain the exact helper path, runtime profile,
and connection UUID. Do not infer these from an app name or another connection.
For context, select the intended agent and choose **Share Session Details…** on
that connection. Terminal history requires separate consent.

Dot needs its own connected-Mac permission: in Dot's profile in ChatGPT on the
Mac, choose **Computers → Your computer → Allow access**. Keep the Mac online
and the ChatGPT app open. Codex's computer connection and Work Sync do not grant
this permission. Ask Dot to create a **new local task** on that Mac and load this skill. That
local task calls the helper; it does not depend on Dot exposing the helper in
its own tool catalog.
If local execution or skill discovery is unavailable, report that limitation;
do not run the helper on Dot's cloud computer.

The local Codex task can discover an installed skill under
`~/.agents/skills/awesomux-read-only/`. ChatGPT desktop also offers its Skills
surface. Verify actual discovery in the task; directory presence alone is not
proof that Dot can use it. Installation does not register or enable app access.

In the maintainer's tested ChatGPT app, that user-level folder was absent from
the task catalog. A compatibility link from `~/.codex/skills/awesomux-read-only`
to the reviewed installed folder enabled discovery in a fresh task. If this
occurs, explain the observed workaround to the user; inspect any existing
destination rather than overwriting it. Do not install or modify catalog paths
as part of an ordinary status/context request.

### Saved connection setup

After reviewing the repository skill resources and the values from **Copy Setup
Command**, use `python3 -B script/install-dot-skill.py` in the reviewed checkout.
It installs or updates only `SKILL.md` and this reference under
`~/.agents/skills/awesomux-read-only/`, backing up changed owned files and
preserving other installed files. It does not change catalog compatibility links.

To save setup once, add all three literal options: `--helper-path`, `--profile`,
and `--connection-id`. The installer writes only `schemaVersion`, `helperPath`,
`profile`, and `connectionID` to
`~/.config/awesomux/read-only-connection.json`, atomically with mode `0600`.
Running without setup options leaves configuration unchanged. Different saved
values require explicit `--replace-connection` after review and retain a backup.
A reviewed replacement can repair a missing old helper. Malformed or unrelated
configuration is preserved: move it aside after review before saving new setup.
An absolute executable helper may itself be a symlink only when its path has
been explicitly reviewed; the installer never resolves it to a different saved
path. Run one setup operation at a time; installation is separate from ordinary
reads.

At read time, parse the configuration as JSON and require exactly those keys,
integer schema version `1`, string setup values, a user-owned regular file with
mode `0600`, and no symlink in its path. Validate the absolute executable helper,
exact profile syntax listed below, and hyphenated UUID. Do not source the file or
execute its contents. Stop for malformed, unsupported, unreadable, or stale
configuration and request setup review; do not probe another connection/profile.
If the file is absent, request reviewed setup values. Never save or rewrite setup
as part of a status/context read. Every read still checks connection status,
capabilities, and app grants; the UUID is not a credential.

## Commands

These are templates, not commands to run with placeholder values. Construct
an argument array from the reviewed setup values. When only a shell execution
tool is available, quote each literal argument safely; do not interpolate
untrusted names/content or evaluate the copied setup command.

```text
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_connection_status
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_capabilities
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> list_agents
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_attention_events --limit 100
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_attention_events --limit 100 --cursor <saved nextCursor>
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_agent_context --pane-id <pane UUID> --target-version <target UUID> --limit 24576 --source transcript
```

The helper is inside `awesoMux.app/Contents/MacOS/awesomux-agent`.
Profiles are `production`, `development`, or
`development:<12 lowercase hexadecimal worktree ID>`; there is no fallback.
`--source terminal_history` is valid only for an explicitly requested and
separately permitted terminal-history read.

The helper prints one JSON object and exits 0 on success, 1 on failure. Parse
that JSON even when the execution tool reports a nonzero exit. Never substitute
an empty list or partial stdout for an error. Failed process launch or malformed
output is a local execution failure, not an awesoMux success.

## Responses

Successful responses identify `schemaVersion`, `requestID`, `profile`,
`appInstanceID`, and `capturedAt`. Preserve these when recording evidence.
Status rows include `paneID`, `workspaceID`, `workspaceName`, `targetVersion`,
provider/session identity, state, attention, and observation metadata. Pane
titles are not included. Names are
display values, not identity or authorization.

`get_connection_status` may return `contextGrant` with `paneID`, `targetVersion`,
and `allowTerminalHistory`. These configure the permitted target independently
of the roster; they do not prove it is still live. The content read revalidates it.

`agentContext` returns `paneID`, `workspaceID`, `targetVersion`, `provider`,
`providerSessionID`, `source`, `capturedAt`, `content`, `byteCount`, `truncated`,
and `untrusted: true`. The maximum content budget is 24 KiB of UTF-8.
Terminal history can include earlier programs and does not claim transcript
identity. Missing transcripts never imply permission to read history.

## Recovery

### Attention checks

The API advertises `attentionEvents: true` and `monitoring: false`: it exposes
readable history, not a subscription or notification service. A client task may
check it periodically using its own scheduler. Dot needs the connected Mac
route above for every run. Confirm the saved task, cadence, end time, and chat
where Dot should post updates. Local task results are expected to appear in the user's Dot chat, and ChatGPT may
alert the user on their phone according to notification settings. The helper does not target a phone or send push alerts.

For a bounded recurring status snapshot, call `get_connection_status`,
`get_capabilities`, and `list_agents` on each run. No event cursor or durable
checkpoint is required. This reports current authorized state and may miss
attention raised and resolved between runs. Describe that limitation explicitly;
do not present snapshots as complete event monitoring. Verify unattended Dot
chat updates separately from whether ChatGPT alerts the user on their phone.
Inability to target or verify a phone push does not prevent chat updates.

Keep one reader active for this helper, profile, and connection. If an earlier
run is still active, do not start another. Preserve the checkpoint and pending
events; report that the check was skipped because the reader was busy.

Agree on the chat destination and fields to share. Forward only attention
metadata, never session context. Keep the cursor used to request each page
alongside any pending events. Immediately before reporting an event, reread
that page with the same cursor and limit, and confirm that
`attentionEvents.cursorStatus` is `current` and the page still includes that event ID.
A successful connection check or current roster is not enough to validate an
older event. If the event is missing, the reread returns another status or an
error, or access cannot be checked, stop checks rather than forwarding it. The
check cannot recall messages already sent or guarantee that access stays
unchanged after the read.

The remainder of this section describes complete event monitoring within the
API's retained history, with explicit gap reporting. Before starting, verify
that the task can retain a checkpoint for this exact
helper/profile/connection between runs. Keep the opaque cursor, each pending
page's request cursor and limit, handled event IDs, and unresolved attention IDs
in the task's private state, without credentials or transcripts. If durable task state is unavailable, explain the
limitation and stop; do not silently restart from history on each run or create
a new file-based service.

1. Establish a silent baseline: call `get_attention_events --limit 100` without
   a cursor, then drain every page using `nextCursor` while `hasMore` is true.
   Record retained events without sending them as new alerts. Call `list_agents`
   and report the current authorized state once. Save the completed baseline
   checkpoint before claiming checks have started. The retained history is
   bounded to 512 changes and does not prove earlier coverage.
2. On each later run, use the saved cursor and drain all available pages. Events
   contain stable `id`, `attentionID`, `change`, `reason`, `paneID`,
   `workspaceID`, `provider`, `targetVersion`, and `occurredAt`. Pair `raised`
   and `resolved` by `attentionID`, including across pages and runs. Report a
   brief alert that has already resolved as such, rather than as still waiting.
   Resolutions do not prove successful completion. Use names only when an
   authorized roster supplies them; closed panes may have only IDs.
3. Deduplicate handled event IDs. Commit each page's `nextCursor`, unresolved
   attention map, and handling result together after handling its events.
   Retain event IDs only for a page that might be replayed after an interrupted
   commit; prune them once that page's cursor is committed. Remove resolved
   attention entries after handling their resolution.
   Retry only when delivery clearly was not accepted, and only before the task's
   end time. If delivery might have been accepted but its response was lost,
   stop and record the uncertain outcome. Do not retry unless the receiver has
   proved it deduplicates the same event ID. An accepted request alone does not
   prove a chat response or phone alert.
   If pagination cannot finish within a run, retain the last handled checkpoint
   and report delayed coverage; never describe a partial drain as up to date.
4. On `history_gap` or `app_restarted`, retain the fresh cursor returned by the
   recovery page and discard pre-gap pending delivery. Report the gap, call
   `list_agents` for authorized current state, then resume from that fresh cursor.
   Replace the old unresolved map with the recovered state. Do not present the
   recovered baseline as new alerts or claim to reconstruct missed events.
5. On `access_changed`, stop checks and discard pending delivery. Require
   review of the changed access before restarting. Do not handle it as a history
   gap. On revoked or denied access, also stop and discard pending delivery.
   On `stale_target`, stop and discard pending delivery, then require target
   review; never choose another pane or broaden the grant automatically.
   On `invalid_cursor`, stop checks and explain the required setup review. Do not
   restart a baseline without explicit user direction.
   On app, route, or execution failure, report unavailable rather than idle.
   Retain the last successful checkpoint for a later authorized retry.

Before calling the workflow verified, exercise one real native attention
transition, a later resolution, checkpoint reuse in a separate task run, and
an app/route failure. Record the actual client, app/profile, read times, observed
results, and the Dot chat receiving updates. If phone alerts are part of the
trial, the user must separately observe whether ChatGPT alerts them on their
phone. Skill discovery, helper responses, and a saved schedule alone do not
prove unattended chat updates or phone alerts.

### Read failures

| Failure | Next step |
| --- | --- |
| Local task/Mac unavailable | Report the route failure; the user can bring the Mac online with ChatGPT open or review Dot's connected-Mac permission. |
| `app_unavailable` | The user can open the intended build; retain the configured profile. |
| `credential_unavailable` | A credential may be missing or inaccessible under restricted execution. Review the execution environment and connection; see below. Never extract Keychain credentials. |
| `access_disabled` / `permission_denied` | The user can review global access, status scope, or session sharing in awesoMux. Do not expand access automatically. |
| `stale_target` | Refresh authorized metadata, then ask for a new explicit selection. |
| `no_session_identity` / `process_identity_unknown` | Explain that exact live session identity is unavailable. |
| `unsupported_provider` / `remote_context` | Explain that this context source is unsupported; do not read files or use SSH instead. |
| `context_unavailable` / `context_too_large` | Report the source failure or size refusal; no implicit source fallback. |
| `transport_failure` / `timeout` | Report the failed read; no partial content or stale cached success. |
| Profile/endpoint/schema errors | Report the exact error and have the user review setup; do not probe other profiles. |

Ad-hoc builds may cause Keychain trust prompts when the helper identity changes.
The user should inspect the displayed binary path. Dot's automatic action review
also applies; the skill cannot suppress platform-required approvals.

In the maintainer run, restricted execution returned `credential_unavailable`,
but normal reviewed escalation of the same helper succeeded with unchanged
credentials and grants. If the host supports execution approval, request its
normal approval for the exact configured helper and named read operation.
Proceed only when approved; if unavailable or denied, stop and report the
limitation. Do not weaken the sandbox globally, broaden grants, change profiles,
or use a credential export to make a denied call succeed. Persistent failure
after approved execution requires reviewing the connection and helper trust.
