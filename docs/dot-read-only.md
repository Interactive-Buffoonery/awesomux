# Read-only awesoMux access from Dot

The `awesomux-read-only` local skill lets a task on a connected Mac invoke the
bundled helper for authorized agent status and explicitly shared session context.
It does not send terminal input. [Maintainer testing](https://github.com/Interactive-Buffoonery/awesomux/pull/728#issuecomment-6003148028)
confirmed phone-triggered local status reads and selected-session context isolation
on the Mac development build. The remaining failure and accessibility checks
are listed in the validation record.

## Requirements

- A Dot-enabled ChatGPT account and a supporting mobile app update. OpenAI is
  rolling out access; account eligibility must be checked on the actual account.
- A Mac online with the ChatGPT app open, connected through Dot's profile under
  **Computers → Your computer → Allow access**. This permission is separate
  from Codex's computer connection and Work Sync.
- A running awesoMux build with its own reviewed connection and grants.
- A local Work or Codex task that can discover the skill and execute the exact
  bundled helper. Dot's cloud computer has a separate filesystem and cannot
  access the Mac's Keychain or socket.

OpenAI documents these requirements in [Connect computers and apps](https://learn.chatgpt.com/docs/dots/computers-and-apps)
and [Tasks and memory](https://learn.chatgpt.com/docs/dots/tasks-and-memory).
Sources were checked on 2026-10-05. Skill discovery was verified in a fresh
phone-triggered local task using the compatibility link described below.

## Prepare the local skill

The app build already bundles the source skill at:

```text
awesoMux.app/Contents/Resources/AgentIntegrations/openai/skills/awesomux-read-only/
```

From this repository, produce a reproducible archive without installing it or
changing access:

```sh
mkdir -p .build/dot-skill
python3 -B script/package-dot-skill.py .build/dot-skill/awesomux-read-only.zip
```

The packaging command refuses existing output files. Choose a new filename for
another build. The ZIP contains one skill folder and its helper reference; no
Mac-specific helper path, connection handle, or credential is included.

For a local Codex task, review the two source resources, then install or update
them from the reviewed checkout:

```sh
python3 -B script/install-dot-skill.py
```

The installer owns only `SKILL.md` and `references/helper.md`. Changed files get
sibling backups; unrelated installed files are preserved. Symlink destinations
and unexpected file types are refused. Setup runs should be serialized.
The command leaves existing connection configuration and catalog links unchanged.
OpenAI documents that user-level discovery location in
[Build skills](https://learn.chatgpt.com/docs/build-skills). The ChatGPT desktop
app also offers a Skills surface. Confirm that the new local task can load this
skill; presence on disk alone does not prove Dot task discovery. No public
plugin submission or hosted service is required for this experiment.

### Catalog compatibility

In the tested ChatGPT app, the skill installed under `~/.agents/skills/` did not
appear in the local task's catalog. A link from
`~/.codex/skills/awesomux-read-only` to that installed folder made it discoverable
in a fresh task. This is an observed compatibility step for that app, not a
requirement established for every version.

If the installed skill is missing from the catalog, review both locations first.
If `~/.codex/skills/awesomux-read-only` already exists, inspect it rather than
overwriting it. With the installed skill reviewed and that destination absent:

```sh
mkdir -p "$HOME/.codex/skills"
ln -s "$HOME/.agents/skills/awesomux-read-only" "$HOME/.codex/skills/awesomux-read-only"
```

Start a fresh local task and confirm discovery again. This setup step does not
enable awesoMux access or modify its grants.

Run the intended awesoMux build. Local repository builds use their development
profile; installed/release builds use production. Never substitute one profile
for another. In **Settings → Agents → Outside app access**:

1. Add a dedicated connection and review its status scope.
2. Enable global access.
3. Use **Copy Setup Command** to obtain the reviewed helper path, profile, and
   connection UUID. Save those reviewed values once from the checkout, passing
   each literal argument safely (these placeholders must be replaced):

   ```text
   python3 -B script/install-dot-skill.py --helper-path <absolute executable helper> --profile <exact profile> --connection-id <UUID>
   ```

   All three options are required together. Saved JSON at
   `~/.config/awesomux/read-only-connection.json` contains only schema version
   `1`, helper path, profile, and connection ID, with mode `0600`. Different
   existing values require explicit `--replace-connection` after review and are
   backed up. Invalid or unrelated config is refused rather than overwritten.
   This local file is never included in the portable ZIP.
4. Only if session context is requested, select one agent and choose
   **Share Session Details…** for that connection. Status-only checks need no
   context sharing. Leave terminal history off unless specifically requested
   and reviewed.

Credentials remain in the standard Mac Keychain. Ad-hoc development builds can
trigger a Keychain trust prompt; inspect the exact helper path before allowing
it. Registering the connection or installing the skill does not establish Dot's
computer permission. Both sets of controls are required.

### Restricted execution and Keychain access

The tested restricted task returned `credential_unavailable`; the same exact
helper succeeded through the host's normal reviewed execution escalation,
without changing credentials or grants. This error does not distinguish a
missing credential from one inaccessible to the current execution environment.

If execution is restricted, use the host's supported approval flow for the
exact helper path, profile, connection, and read operation. Continue only if
that request is approved. If the host has no such flow or approval is denied,
report the limitation. Do not extract credentials, weaken the sandbox globally,
change grants, or silently switch profiles. If the reviewed execution still
fails, inspect the connection and any Keychain trust prompt for that helper.

## Try it from the phone

Start two dedicated real agents with harmless, different markers, for example
`FIRST SESSION SAMPLE` and `SECOND SESSION SAMPLE`. Let the dedicated connection
list both, but share context for only the first.

Ask the same Dot from the phone:

```text
Create a new local task on my connected Mac and use awesomux-read-only to list
the authorized awesoMux agents. Do not send input to either agent. Use the
reviewed saved connection setup on that Mac.
```

Then select the intended pane explicitly and ask for its shared transcript.
The roster returns workspace names and pane IDs, not pane titles. If names are
ambiguous, the task must ask you to choose. Confirm the first marker is returned
with source, provider/session identity, capture time, byte count, and truncation
metadata. An attempt to read the second pane must fail without returning its
marker. Keep terminal history off for this transcript proof.

## Short recurring status trial

Ask Dot to create a new local task using this skill and the saved connection.
Explicitly agree on a short cadence, end time, destination, and which changes to report. Use ChatGPT's supported recurring task mechanism. Each run checks
connection status and capabilities, then `list_agents`; it needs no event cursor.
Snapshots may miss attention raised and resolved between runs, and waiting does
not prove work completed. Local tasks are expected to report results back to Dot in your Dot chat; unattended
updates are not yet verified. ChatGPT can alert you on your phone according to its
notification settings. Verify unattended chat updates and observed phone alerts
separately; the local task does not need to target or verify phone push delivery.

Suggested phone prompt for a bounded trial:

```text
Create a new local task on my connected Mac. Load awesomux-read-only and use
its reviewed saved connection setup. Run a status snapshot every 2 minutes
for 10 minutes, then stop. Report each result back to me here in our Dot chat,
including if the Mac, helper, app, or access is unavailable. ChatGPT can alert
me on my phone according to my notification settings; the local task does not
need to send or verify a phone push notification. Check
connection status and capabilities, then list the authorized agents. Do not
read session context or send agent input. Show when each status was last seen, separately from when you checked; snapshots can miss changes and do not prove complete event
coverage or successful work completion. Use ChatGPT's supported task mechanism.
If scheduling or local execution is unsupported, state that limitation instead
of claiming the task was created.
```

This is a proposed trial, not a recorded successful task. ChatGPT-owned recurring
execution and unattended Dot chat updates remain unverified until observed.
Record the saved task, first/later read times, unavailable result, and stopping
after the final check. Separately record whether ChatGPT alerted the user on
their phone.

Complete event monitoring is a separate contract: it requires a silent baseline,
durable cursor/checkpoint reuse, full pagination, deduplication, and visible gap
recovery. Follow the skill's helper reference before promising that coverage.
The local skill and helper do not implement a scheduler or notification service.

## Acceptance record

Record app/build SHA, ChatGPT/mobile versions, helper path, exact profile,
task IDs, connection handle, steps, and redacted outputs. Never record credentials
or private transcript contents. Use screenshots or a recording where they make
the route and results verifiable. Capture each scenario independently:

| Scenario | Required observation |
| --- | --- |
| Two real agents | Scoped status matches native provider/state/attention; no invented observation freshness. |
| One enabled transcript | Exact selected session and marker returned; the other session's context is denied. |
| Ambiguous names | Explicit pane selection before a context read. |
| App exit | Helper reports unavailability; no empty roster or cached transcript presented as success. |
| Mac offline | Dot reports the local route unavailable; no cloud helper substitution. |
| Stale selection | Replace/restart the agent after selection; old target fails and a new selection is required. |
| Sharing disabled | Stop sharing details; context denied while remaining status scope still works. |
| Global access disabled | All app operations denied. |
| Connection revoked | Future helper reads denied or credential unavailable. |
| Connected-Mac access revoked | Dot cannot start further work through that Mac connection. Inspect/stop any already-running local task separately. |
| Native setup | Inspect Settings, keyboard/VoiceOver behavior, and any Keychain trust prompts. |
| No input | Compare both real agents before/after; the workflow issues only the permitted read operations. |

Revocation cannot recall information already returned to the assistant service.
The connected-computer permission can be broader than awesoMux's helper grants.
Dot's automatic action review still applies; custom instructions cannot bypass
required approvals. See [Control your Dot](https://learn.chatgpt.com/docs/dots/controls).

Before merging, review the outstanding acceptance checks in the validation
record. Phone-triggered status and Mac-side transcript isolation have maintainer
evidence; a phone-requested transcript read and the remaining failure/accessibility
cases were not recorded. Automated fixture runs do not establish those checks.

## Automated evidence

The [recorded local run](dot-read-only-e2e-report.json) separates passing package
and preflight checks from the Keychain-blocked API E2E and pending manual checks.

```sh
python3 -B script/test-dot-skill-package.py .build/dot-skill-evidence/package
python3 -B script/test-dot-skill-install.py .build/dot-skill-evidence/install
./script/ensure_ghostty_artifacts.sh
swift build --product awesomux-agent
swift build --product local-api-e2e
BIN="$(swift build --show-bin-path)"
"$BIN/local-api-e2e" "$BIN/awesomux-agent" .build/dot-skill-evidence/local-api
./script/preflight.sh
```

The packaging driver records a reproducible archive hash, source equality,
extraction, refusal to overwrite, missing resources, and symlink refusal.
The installation driver uses disposable home directories to verify owned-file
updates and backups, saved-config reuse and explicit replacement, invalid setup,
symlink refusal, mode `0600`, and preserved unrelated files/configuration. Its
report does not establish real helper access or Dot discovery.
The existing local API E2E driver exercises the real helper, Keychain and socket
against labeled provider/history fixtures. Its context scenarios include one
selected transcript, another session's refusal, source consent, limits, stale
identity, and revocation. Preserve its reports separately from packaging evidence.
Preflight runs the existing automated suites and signing/launch verification;
it does not establish Sarah's hands-on acceptance.

See [the helper contract](local-agent-api.md) for exact API behavior.
