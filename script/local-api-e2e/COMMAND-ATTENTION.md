# Command completion attention integration

Failure model (written before implementation):

- Shell completions disappear because the agent-state projection excludes shells.
- Unknown status, startup prompts, or short commands create false alerts.
- Nanoseconds are mistaken for seconds, or exit code/duration are lost in JSON
  or the Companion response adapter.
- Repeated identical completions collapse into one state alert.
- A completion resolves an unrelated permission alert, or native focus/unread
  changes suppress or acknowledge it.
- A deferred callback reports against a replacement terminal assignment.
- Events leak outside the existing authorization scope, or evade journal bounds.

The `local-api-e2e --command-attention-only ARTIFACT_DIRECTORY` mode drives the
typed completion/store boundary through a real authenticated local socket. It
also checks the Companion adapter, state-alert coexistence, target replacement,
and retained-history recovery. It uses disposable bearer registrations, without
Keychain, native UI, a shell process, or a paired phone. The existing attention
socket harness retains broader cursor/authentication lifecycle coverage.

Queue from this checkout (do not run concurrently with another heavy job):

```sh
heavy-gate -- swift run local-api-e2e --command-attention-only /private/tmp/command-attention-790
```

Use a fresh artifact directory. A successful run writes `command-attention.json`
with every named check. This is integration evidence, not proof of real OSC133
delivery. Native shell integration, initial prompt behavior, background/focused
panes, and the phone's interpretation still need runtime verification. The
Companion protocol dependency must include optional `exitCode` and
`durationSeconds` before this host layer can compile.
