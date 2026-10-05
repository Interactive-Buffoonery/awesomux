# Read-only awesoMux access from Dot

The `awesomux-read-only` local skill lets a task on a connected Mac invoke the
bundled helper for authorized agent status and explicitly shared session context.
It does not send terminal input. Real phone-to-Dot-to-Mac acceptance is pending;
the package and local API can be checked independently before that run.

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
Sources were checked on 2026-10-05. Local skill discovery and permission prompts
still need verification in the actual Dot-created task.

## Prepare the local skill after opening the draft PR

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

## Try it from the phone after opening the draft PR

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

Keep the PR in draft and INT-1201 open until this real run and failure cases have
been reviewed. Automated fixture runs do not prove phone routing, skill activation,
real-provider behavior, native history, or hands-on accessibility.

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
