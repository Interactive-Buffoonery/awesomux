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

For a local Codex task, extract that folder into `~/.agents/skills/` only after
reviewing its contents. Do not overwrite an existing installation without
reviewing it. OpenAI documents that user-level discovery location in
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
   connection UUID. Provide this nonsecret setup data to the local task.
4. Select one agent and choose **Share Session Details…** for that connection.
   Leave terminal history off unless it is specifically needed and reviewed.

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
Create a local task on my connected Mac and use awesomux-read-only to list
the authorized awesoMux agents. Do not send input to either agent. Use the
setup values I supplied for this connection.
```

Then select the intended pane explicitly and ask for its shared transcript.
The roster returns workspace names and pane IDs, not pane titles. If names are
ambiguous, the task must ask you to choose. Confirm the first marker is returned
with source, provider/session identity, capture time, byte count, and truncation
metadata. An attempt to read the second pane must fail without returning its
marker. Keep terminal history off for this transcript proof.

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
| No input | Compare both real agents before/after; the workflow issues only the four read operations. |

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
./script/ensure_ghostty_artifacts.sh
swift build --product awesomux-agent
swift build --product local-api-e2e
BIN="$(swift build --show-bin-path)"
"$BIN/local-api-e2e" "$BIN/awesomux-agent" .build/dot-skill-evidence/local-api
./script/preflight.sh
```

The packaging driver records a reproducible archive hash, source equality,
extraction, refusal to overwrite, missing resources, and symlink refusal.
The existing local API E2E driver exercises the real helper, Keychain and socket
against labeled provider/history fixtures. Its context scenarios include one
selected transcript, another session's refusal, source consent, limits, stale
identity, and revocation. Preserve its reports separately from packaging evidence.
Preflight runs the existing automated suites and signing/launch verification;
it does not establish Sarah's hands-on acceptance.

See [the helper contract](local-agent-api.md) for exact API behavior.
