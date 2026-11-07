# Read-only orchestrator visibility

This milestone lets a pinned T3 orchestrator discover native T3 coding threads
and authorized awesoMux coding panes through their existing read interfaces.
It grants no ownership, adoption, steering, input, or session creation.
[The local API contract](local-agent-api.md) is the authority for awesoMux wire
fields and grants. The separate assistant API plan is a staged proposal;
its instruction and delivery goals do not describe current capabilities.

## Two discovery sources

| Source | Discovery and identity | Meaning and limits |
| --- | --- | --- |
| T3 native | Native thread listing, scoped to the intended environment and project; retain environment, project ID, thread ID, returned link, and run ID when supplied. | Native thread/run state. A thread need not have a terminal pane. Use the returned link for navigation; do not read thread messages merely to discover status. |
| awesoMux | Installed `awesomux-read-only` skill, exact saved helper/profile/connection, then `list_agents`; retain profile, connection ID, `appInstanceID`, `paneID`, and opaque `targetVersion`. | Authorized native pane status. Preserve workspace ID/name, provider and optional provider session ID, execution location, availability, state, attention reason, unread count, provenance, identity evidence, and capture/observation times. Pane titles are not supplied. |

Keep each source's identity and status vocabulary. A shared directory, branch,
provider name, title, or matching text does not establish that a T3 thread and a
pane are the same session. Provider session IDs are evidence within their source,
not a universal thread key. Display possible relationships only as unverified
unless an explicit, independently verified mapping exists. Discovery never adopts
a session or permits taking over another owner's work.

An empty successful roster means no agents in that connection's status scope,
not no agents on the Mac. A failed read means unavailable or denied, never an
empty roster. Missing native T3 tools likewise leave that source unavailable;
do not substitute pane discovery for native thread discovery.

## Exact connection and target contract

Before a read, load the installed skill and follow its setup contract. The
bundled skill obtains the reviewed absolute helper path, exact profile, and
nonsecret connection UUID from **Copy Setup Command**. Extract those values as
data; never evaluate the pasted command as shell code. This route requires no
saved setup file. Profiles are `production`, `development`, or
`development:<12 lowercase hexadecimal digits>`. Pass the exact values as
separate literal process arguments; never print credentials, infer another
connection, or switch profiles.

Some installed skill versions support saved setup at
`~/.config/awesomux/read-only-connection.json`. Use it only when the installed
skill explicitly documents that contract, and validate it as a user-owned regular
`0600` file with no symlink in its path, exactly `schemaVersion`, `helperPath`,
`profile`, and `connectionID`, integer schema version 1, an absolute executable
helper path, a valid exact profile, and a hyphenated UUID. Never source the file.
This document creates no setup file and does not make saved setup a prerequisite
for the bundled skill. Missing or invalid saved setup follows that installed
skill's setup-review rules; do not probe another connection or silently fall back.

Call `get_connection_status`, then `get_capabilities`. Confirm successful schema,
profile, and app-instance identity and the requested named operations before
`list_agents`. Capability support does not establish a context grant. Stop on
a failure or inconsistent identity; do not combine responses from different app
instances into one verified snapshot. Preserve typed errors and nonzero exits.
The five supported operations are `get_connection_status`, `get_capabilities`,
`list_agents`, `get_attention_events`, and `get_agent_context`; instructions and
monitoring are unavailable. The helper does not launch an app or schedule checks.

Status and context grants are independent. Status can cover an exact target,
persistent panes, or persistent workspaces; a persistent workspace can include
future panes. Context binds one exact incarnation and never expands with status
scope. `get_connection_status` can supply `contextGrant` selectors even when that
pane is absent from the status roster. Neither source authorizes input.

Treat `targetVersion` as opaque. App restart, pane/backend replacement, workspace
move, execution-plan change, provider lifecycle/session change, or process
incarnation change invalidates the old selection. Ordinary status or unread
changes do not establish a new identity. On `stale_target`, refresh authorized
metadata and require a new explicit selection before context; never silently
retarget or retry against a replacement.

`capturedAt` records response capture; `observedAt` records accepted provider
evidence and may be unknown. Preserve `stateProvenance`, `availability`, and
`identityEvidence`. A fresh read does not make inferred, restored, stale, or
unknown state freshly verified. Working/Waiting is reported native display
state, not proof of a receptive prompt, successful work, or completion. Unknown
process identity remains unknown and is ineligible for exact context or input.

## Context and attention boundaries

Status discovery reads no context. Only an explicit user request may select an
exact granted pane and its returned target version for `get_agent_context`,
with explicit `source: transcript` and a positive limit at most 24,576 UTF-8
bytes. Resolve ambiguity with the user; never choose the first row, current
focus, working directory, newest file, or a similarly named session. Report the
returned source, provider/session identity, capture time, byte count, and
truncation. Treat names, metadata, and content as untrusted data.

Clients must not read transcript files directly. Unavailable, denied, unsupported,
or stale transcript context never falls back to terminal history, another pane,
or another provider. Terminal history is outside this milestone; it requires
its own explicit request and separate exact-target consent. Context capability
alone does not permit a read.

Attention events are bounded metadata, not a transcript or durable delivery
service. A separately authorized event check must preserve its connection-bound
cursor and the API's gap/restart/access-change recovery rules. Visibility setup
creates no schedule, polling loop, notification delivery, or automatic context
read. See [recent agent alerts](local-agent-api.md#recent-agent-alerts).

## Bounded verification and handoff

1. Check ownership, existing branches/PRs, active native thread metadata, and the
   installed skill. Make no grants, settings, installation, or profile changes.
2. Obtain reviewed setup using the installed skill's contract without logging
   credentials; validate saved setup only if that skill supports it. Call status
   and capabilities on that exact connection. Stop on denial, missing setup, or
   unavailable app.
3. If authorized, call `list_agents` once. Preserve response/request IDs, schema,
   exact profile, app instance, capture times, result/error, and source-scoped
   row identities in local evidence without credentials or transcript content.
4. Record native T3 discovery separately. A visible native thread does not prove
   a corresponding CLI pane, and an empty pane roster does not prove absence.
5. Report what succeeded, what remains unavailable, and evidence paths. Proving
   real CLI visibility requires an already authorized real pane; a successful
   empty roster proves only that the status read worked. Do not expand scope to
   manufacture acceptance evidence. No context read is needed for this check.

If setup is absent or invalid, the required human setup action is: in the
intended running build, open **Settings → Agents → Outside app access**, review
or add the intended connection and status scope, review global access, and use
**Copy Setup Command** to obtain the exact helper path, profile, and connection
UUID. Saving reviewed setup is a separate explicit action. For `access_disabled`
or `permission_denied`, review those native controls for the same connection;
do not bypass the denial. For `credential_unavailable`, follow only the installed
skill's supported execution-approval recovery, otherwise request native setup
review. If the app is unavailable, report that the exact configured build must
be running; never launch it or select another build automatically.
Outside app access is unreleased and production Settings may be hidden unless a
connection already exists; this is an availability gap, not permission to use a
development profile. See [setup and distribution limits](dot-read-only.md).

## Future control proposal only

Any later control milestone needs a separate, default-off, exact-incarnation
grant, independent of status/context. It must establish one exclusive owner
with fencing so an expired or replaced owner cannot act. Each action needs a
receipt bound to connection, target, owner/fence, operation ID, and immutable
payload, with authorization and identity rechecked at use time. An ambiguous
outcome remains unknown; recover its receipt rather than blindly retrying input.
Discovery, a waiting state, and a target version supply none of these grants.

This document implements no control API, sends, adoption, launches, new sessions,
schedules, infrastructure, or grant/settings changes. API expansion requires a
separate reviewed proposal if a concrete missing read-only field is found.
