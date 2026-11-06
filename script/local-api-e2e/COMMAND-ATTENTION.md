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
- Legacy clients receive command facts as permanent state alerts without opting in.
- Filtering command facts after pagination hides or delays state alerts.
- A cursor is reused across state-only and command-inclusive modes.
- The opt-in field is accepted for another operation, even when false.
- Events leak outside the existing authorization scope, or evade journal bounds.

The `local-api-e2e --command-attention-only ARTIFACT_DIRECTORY` mode drives the
typed completion/store boundary through a real authenticated local socket. It
also checks the Companion adapter, state-alert coexistence, target replacement,
and retained-history recovery. The revised harness explicitly opts in for command
reads, checks omitted/false requests against the same state alerts, verifies
filtering before pagination, rejects cross-mode and cross-connection cursors,
and rejects the opt-in field on other operations even when false. It uses
disposable bearer registrations, without Keychain, native UI, a shell process,
or a paired phone. The existing attention
socket harness retains broader cursor/authentication lifecycle coverage.

Queue from this checkout (do not run concurrently with another heavy job):

```sh
process-gate -- swift run local-api-e2e --command-attention-only /private/tmp/command-attention-790
```

Use a fresh artifact directory. A successful run writes `command-attention.json`
with every named check. This is integration evidence, not proof of real OSC133
delivery. Native shell integration, initial prompt behavior, background/focused
panes, and the phone's interpretation still need runtime verification. The
Companion protocol dependency must include optional `exitCode` and
`durationSeconds` and the optional `includeCommandEvents` request field for typed
clients. New clients must send true for every command-inclusive page; to change
modes they must omit the old cursor and start a new stream. Existing requests
default to state-only delivery. JSON null follows the optional-field convention
and also defaults to false; other non-boolean values are invalid.
