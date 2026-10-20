# Local Claude permission helper fixture

This drives the real `awesoMuxAgentHook` process with synthetic hook stdin and
an owner-only socket/file peer. It does not prove Claude's interactive prompt
races, native UI, VoiceOver, or provider execution.

All builds and fixture runs require the machine-wide heavy-gate lease. Use the
repository build/test scripts and a foreground job with scoped Xcode-helper
cleanup. For an already built helper, inside that same gated job:

```sh
python3 script/local-permission-e2e/run.py \
  --helper .build/debug/awesoMuxAgentHook \
  --output /private/tmp/822-helper-evidence-UNIQUE \
  --include-timeout
```

The output directory must not exist. `result.json` lists completed cases;
a nonzero runner exit means failure even if some cases already passed. The
optional timeout case takes the actual 120-second helper budget. The remaining
seven cases exercise bridge allow/deny, file allow/deny, bridge disconnect with
an unchanged invocation, fragmented socket responses, and broken stdout with
no ACK on either transport. Fixture payloads include sentinel file-content and
tool-response secrets; they must never appear in runtime telemetry or requests.
Fixtures omit `tool_use_id`, as Claude's PermissionRequest contract does.

# Routing and delivery

ADR-0028's primary local routing uses an app-owned Unix socket built with the
existing command bridge's secure listener-directory primitive. It deliberately
uses a separate local request lane: the remote legacy lane replaces its active
connection and has automatic-deny/session policy. This change does not alter
remote frames, remote policy, the zmx daemon, or submodule pins. The local lane
accepts concurrent hook connections, each bound to an app-minted pane target
version. A stable owner-only endpoint descriptor lets fresh hooks in persistent daemon
shells resolve the current runtime target; in-flight hooks retain the old
snapshot. Missing/unreachable sockets fall back to `req-<invocation>.json` and
`dec-<invocation>.json` in a target-scoped directory under runtime events.
Runtime lifecycle JSONL is advisory evidence, never the authoritative queue.
Directory readiness notifications discover fallback records; directory enumeration
runs off the main actor, with at most four concurrent scans and a five-second
backstop when a watch is unavailable. The common socket path does not poll file
queues. Successful immutable decision publication is remembered; failures get
at most five attempts, spaced at least one second apart.

The app's in-memory core owns pending → recorded → delivering → delivered.
Claiming delivery is atomic across both transports. A helper ACK is sent only
after a complete successful stdout write; failed/partial writes and lost ACKs
remain unknown. A claimed answer never reopens, including after fallback.
Recorded/delivered describe the hook, never successful tool execution.

The helper ceiling is 120 seconds; the bundled Claude PermissionRequest hook
has a 150-second timeout, reserving 30 seconds for return/fall-through. Timeout,
malformed input, dead helper, missing endpoint and transport failure produce no
decision, exit 0. Other lifecycle hook timeouts remain 10 seconds. A runtime
restart mints new targets and does not replay old files.

The core keeps at most 128 outcomes until hook expiry plus ten minutes. A
per-target set of at most 4096 seen invocation IDs survives outcome eviction;
capacity exhaustion refuses new requests rather than forgetting old identities.
Target retirement drops authority for all its IDs. Liveness binds the helper
PID to proc_pidinfo birth microseconds and rejects zombies. First verified
pane-capability hook ingress may establish its reported provider session before
lifecycle telemetry; a conflicting session requires a session transition.
No transcript or attention heuristic creates a request. Same-session lifecycle
progress conservatively invalidates matching requests without asserting native
completion. Exact native tool correlation is used only when an ID is supplied.

The card exposes only once-only Allow/Deny and bounded, untrusted review text
(tool name and selected command/path/description, never the raw argument object,
file contents or tool response). Missing or oversized selected review text falls
through to Claude instead of offering approval for a hidden command tail. These
summaries are not logged. It never
focuses on arrival; the existing Focus Permission Prompt command deliberately
focuses it. Bare Return is never approval. Exact rendered identity and a short
successor cooldown protect against stale actions and double clicks. Pending
requests are shown oldest first with a queued count. A successor requires a new
deliberate focus command or button choice. State announcements distinguish
recording, hook delivery, uncertainty and expiry without claiming execution.

Before release, separately drive interactive Claude 2.1.302 on the Mac: local
allow/deny; native-prompt resolution before and after the core commit; helper
exit; target/provider-session replacement; expiry; app restart; bridge loss;
file fallback; dropped reply/ACK; successive prompts; keyboard, VoiceOver and
Full Keyboard Access. The ADR-0028 spike used 2.1.200, so it is not evidence for
the installed version. Current hook documentation also permits hooks before
noninteractive/background auto-denial, which differs from the older headless
observation; documentation does not establish native-prompt race behavior. Remote decisions remain disabled. These instructions
are a verification recipe, not a claim those journeys passed.

Provider contract: https://code.claude.com/docs/en/hooks#permissionrequest-input
