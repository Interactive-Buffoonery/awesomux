# Codex client-event integration checks

Run from a macOS checkout with the repository's Swift toolchain:

```sh
./script/codex-client-events-e2e/run.sh /tmp/awesomux-client-events-e2e
```

The command builds the real `awesoMuxAgentHook` executable, invokes it as a direct child with synthetic callback payloads against a temporary event file, and compiles fixtures against the built Core parser and session runtime, and the tracker sources. Logs and fixture executables remain in the supplied artifact directory. It also compiles the production runtime-event bridge and file reader with a small
composition stub for unrelated application configuration. Real temporary files
exercise initial snapshot skipping, queued revocation draining, source rearming,
strict post-observation timestamps and preserved authority/sequence ordering.
This bridge fixture does not instantiate the app's Send view. No app launch,
native hosted CI, repository test-suite additions, or provider session changes occur.

The helper check covers status mappings, actual parent process identity, producer timestamp preservation, malformed input, stale/future timestamps, the required unsigned completion counter, and the input bound. The parser check covers valid evidence, malformed/null/wrong-source evidence rejection, and legacy compatibility. The tracker check covers replay, sequence order, client/process binding, terminal isolation, expiry, future timestamps, the nondecreasing completion-counter gate, the executable-verification gate, and deterministic rejection of mismatched A/B readiness stamps followed by recovery with matching fresh evidence. The session-runtime fixture exercises the production trust-resolution policy against fresh legacy Codex Stops with empty, recreated and failed-first-callback trackers; it checks native Ready recovery, watch rearm revocation, and unchanged legacy trust for other providers. Stock Codex Send remains unavailable; normal terminal use and the shared daemon are unchanged. The fixture also checks blocked-to-ready and blocked-to-working attention recovery, native thread changes and old tool-state reset, and unavailable-status display preservation through the actual Core session store and reducers. It also checks initial-ready
and acknowledged-heartbeat behavior, background completion exactly once,
focused completion, and thread/client replacement boundaries.

These checks use synthetic producer input and supplied tracker observations. They do not prove that a real Codex TUI emits callbacks, that live foreground-process discovery matches it, or that Markdown actions and readiness behave correctly in the macOS UI. They do not replace full preflight or independent review.
