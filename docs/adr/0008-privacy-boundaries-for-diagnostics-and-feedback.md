# 0008 — Privacy boundaries for diagnostics and feedback

- **Status:** Accepted
- **Date:** 2026-05-17
- **Amended:** 2026-07-21
- **Deciders:** Sarah

## Context

awesoMux is a terminal. Its process tree, session metadata, and agent runtime
signals can sit close to prompts, command output, paths, credentials, and other
private material. Diagnostics must therefore be useful without quietly turning
local state into data collection.

## Decision

### Local diagnostics stay local and ephemeral

The Diagnostics pane may inspect the awesoMux process tree after an explicit
refresh and may sample aggregate CPU and memory while the pane remains visible.
Those samples and the bounded diagnostic event history exist only in memory for
the current app launch. They are not persisted or uploaded.

Diagnostic events use a closed vocabulary of app-owned outcomes. They must not
contain terminal scrollback, prompts, command text, shell output, environment
variables, raw configuration, session titles, workspace names, credentials, or
arbitrary logs.

Locally displayed process metadata and executable paths may still be sensitive.
The UI must remind users to review screenshots or copied diagnostics before
sharing them.

### Feedback remains user controlled

Any feedback or support-report flow must be initiated by the user and show the
complete report in an editable draft before anything is sent. Creating a local
diagnostic summary never authorizes transmission. The app must not submit
feedback, attachments, or diagnostic data in the background.

### Agent status side channels remain content free

Agent integrations may report only the bounded runtime-state events needed for
awesoMux UI state. They must not carry instructions, prompts, tool-call content,
terminal output, working directories, environment values, file contents, or
other free-form session data.

Provider installation and runtime-event acceptance remain explicit opt-in
features under [ADR 0010](0010-opencode-pi-opt-in-agent-integrations.md). Local
side-channel files and sockets must use the repository's owner-only storage and
validation rules.

### No external analytics or automatic error reporting

awesoMux currently includes no product analytics, automatic error reporting,
analytics identifier, analytics event ledger, or analytics network provider.

Adding any external reporting later requires a new ADR. That decision must
define the need, consent model, event and field allowlists, retention, provider
behavior, deletion semantics, and measured startup and runtime cost before code
lands.

## Consequences

Local diagnostics cannot become an implicit transport layer for a future
provider. A new reporting system must establish its own explicit boundary
instead of reusing diagnostic events or agent side channels as payloads.

The app can still help users understand performance and failures locally while
keeping transmission a separate, deliberate product decision.
