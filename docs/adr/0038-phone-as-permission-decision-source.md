# 0038 — The phone as a permission decision source

- **Status:** Accepted
- **Date:** 2026-10-20
- **Accepted:** 2026-10-20 — Sarah accepted the recommendation as written
- **Deciders:** Sarah
- **Issue:** [#793](https://github.com/Interactive-Buffoonery/awesomux/issues/793)

## Amendment (2026-10-23)

2026-10-23: Sarah decided device grants are device-wide, not per workspace.
This supersedes workspace-selection requirements below. Separate default-off
powers and all request identity, eligibility, expiry and release checks remain.
Existing narrower Watch and rename grants widen to every workspace on load.

## Context

[ADR-0028](0028-permission-decision-transport-bridge-primary.md) routes Claude
permission hooks through the command bridge, with a file-pair fallback. Its
native prompt remains answerable while the hook waits, and a returned hook
decision wins. Therefore a single Mac coordinator cannot promise a global
"first human answer wins" across a provider prompt it does not control.

The phone should use that same decision core, not type an approval into the
terminal. [ADR-0035](0035-awesomux-companion-pairing.md) currently allows only
three status reads. This adds pending-decision reads and decision submission
to that allowlist, both requiring a separate Decide grant. Pairing keys, mutual
TLS, network routes, leases and revocation remain unchanged. The corresponding
ADR-0035 scope amendment is recorded in that ADR's Amendment (2026-10-20)
section (landing with ADR-0036, #854).

## Options considered

- **Type into the native prompt:** broadly available, but cannot bind the answer
  reliably to a request or safely deduplicate retries. Keep ordinary terminal
  typing separate from structured decisions.
- **Allow every source and promise first human answer wins:** simple wording,
  but the native prompt is outside the app's transaction and may race the hook.
- **One core for Mac cards and phone, explicit provider uncertainty
  (chosen):** deterministic app decisions without inventing provider
  confirmation. Native-prompt races remain a release gate.

## Decision

**Decision:** start with once-only allow/deny for a live, exactly
identified Claude permission hook. The first valid answer committed by the Mac
core wins among app-controlled sources. Do not claim it wins against an
unobserved answer in Claude's own prompt.

### Authority and request lifetime

- Give each paired device a separate, default-off **Decide** grant, approved on
  the Mac, for explicitly selected workspaces (no all-workspaces default).
  Moving a request outside that scope invalidates device authority. Pairing,
  status, terminal and transcript access do not grant it.
  Require device authentication before submitting an answer, including from a
  lock-screen notification. Notifications carry no authority and show no tool
  summary on the lock screen. Using an action re-reads the request from the Mac
  and submits only if still pending and authorized. Pull-only notifications may
  arrive after the remote window; timely alerts need a separately approved push
  transport.
- Only the decision core creates actionable requests from verified hook ingress.
  Bind a request to runtime instance, pane/target version, provider session,
  hook invocation, request revision, expiry and its supported choices. A
  transcript, terminal string, alert heuristic or device-supplied tool description
  never creates a request. Do not expose provider secrets or unrestricted raw
  tool arguments; show a bounded untrusted summary sufficient to review the action.
- The app's hook identity survives bridge-to-file fallback. Both transports
  attach to one pending request, not two answerable cards. A new invocation or
  restarted app/runtime gets a new identity; old IDs cannot become pending again.
- Recommend a 60-second remote answer window, always shorter than the remaining
  hook lifetime with time reserved to return. At remote expiry, phone actions
  become inert; the Mac card stays answerable until the helper's ADR-0028 timeout,
  when the helper emits no decision and falls through. Transport
  failure never manufactures allow or deny. A request already being delivered
  must finish or become uncertain, never reopen for another answer.
- Hook exit, provider advance, target/session change or transport loss that
  prevents delivery closes the request as cancelled/expired/unknown as supported
  by evidence. Disable actions immediately. Never infer completion from silence.

### Ordering, retries and confirmation

The device sends request ID/revision, allow or deny, and an idempotency ID over
the direct paired connection. The core checks the live hook, exact identity,
expiry and current grant, then atomically commits at most one answer. Mac cards
use the same path. Losing contenders receive the current outcome and source;
they cannot overwrite it. Recheck authority before delivering to the hook.

Bind a retry ID to the authenticated device, request and exact choice. The same
retry returns the same outcome; reusing it with another choice is an error.
Keep bounded outcomes through the hook lifetime plus a short retry window
(recommend ten minutes). Once evicted, return unknown/expired, never execute
again. An app/runtime restart invalidates outstanding requests rather than replaying
decisions. The phone refreshes status after lost replies and never invents a
replacement request ID or queues an approval for offline delivery.

Expose distinct states: pending, answer recorded, delivered to hook, and terminal
outcome (cancelled, expired, or unknown). "Recorded" confirms only the core's
commit. "Delivered" requires the helper to acknowledge its output; it does not
prove the provider performed the tool call. Show the answer's source (Mac or
named device) and authoritative revision through a fresh read or event update.
Use "Allowed on iPhone" only with wording that identifies a recorded decision,
not a claim of successful execution. Old cards and notifications become inert.

### The native-prompt race

If provider progress or native resolution is observed before commit, cancel the
app request. If it is observed after commit but before delivery, stop delivery
where possible and report the observed outcome without issuing a second answer.
If a hook response may already have escaped, report uncertainty; do not retry a
conflicting answer. ADR-0028's hook precedence remains an explicit limitation.

Before enabling remote decisions, test interactive Claude races in both orders,
including native deny versus phone allow, expiry, hook exit, fallback, dropped
replies and revocation. If tests show a hook decision can override an earlier
native answer, or cannot establish the provider's behavior, keep remote decisions
disabled for that provider/version. Sarah can separately choose a clearly explained hook-
precedence policy; this proposal does not silently authorize it.

## Consequences

The local core can ship before the phone. Session-wide rules, free-text answers,
Codex, remote-host providers and transcript-derived controls are deferred. This
narrows the planned once/session surface to once-only until broader authority
and native races have their own evidence. No code or provider-race test is
included in this decision record.

## Open questions for Sarah

Answered by Sarah on 2026-10-20; the recommendation is accepted as written.

1. Start with once-only Claude allow/deny and a separate per-device Decide grant
   limited to Mac-selected workspaces?
   **Decision:** yes.
2. Accept "first core commit wins" and keep remote decisions disabled wherever
   native-prompt races cannot be reconciled, rather than accept hook precedence?
   **Decision:** yes. Hook precedence is not authorized by this record.
3. Choose the proposed 60-second answer window and ten-minute retry retention,
   with device authentication for every approval interaction?
   **Decision:** yes.
