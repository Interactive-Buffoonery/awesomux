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
this permission. Ask Dot to create a local task on that Mac and use this skill.
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

## Commands

These are templates, not commands to run with placeholder values. Construct
an argument array from the reviewed setup values. When only a shell execution
tool is available, quote each literal argument safely; do not interpolate
untrusted names/content or evaluate the copied setup command.

```text
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_connection_status
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> get_capabilities
<absolute helper path> --profile <exact profile> --credential-handle <connection UUID> list_agents
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
