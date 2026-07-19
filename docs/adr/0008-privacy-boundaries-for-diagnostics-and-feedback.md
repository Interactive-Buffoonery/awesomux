# 0008 — Privacy boundaries for diagnostics and feedback

- **Status:** Accepted
- **Date:** 2026-05-17
- **Amended:** 2026-07-18
- **Deciders:** Sarah

## Context

awesoMux is a terminal. Its primary surface may contain commands, prompts,
paths, environment variables, secrets, customer data, proprietary code, and
agent conversations. That makes diagnostics more sensitive than they would be
in a typical productivity app.

At the same time, awesoMux is intended to be free and open source. Maintainers
still need enough information to understand crashes, handled app errors, and
recurring failure modes without asking every user to manually copy logs.

## Decision

Diagnostics that leave the user's machine must be explicit, narrow, and
reviewable.

Product analytics is opt-in, anonymous by default, and governed by an
**analytics consent level**:

- `off` — no background analytics or error reporting.
- `error_reports` — privacy-filtered crash reports and handled awesoMux app
  error categories.
- `product_usage` — future product-shape analytics in addition to error
  reports, still subject to an allowlist.

The durable privacy boundary is stricter than the provider choice:

- Never capture terminal scrollback, prompt text, command text, cwd paths,
  filenames, environment variables, raw config contents, session titles,
  workspace group names, screenshots, session replay, or arbitrary logs.
- Error reports may include sanitized structured context such as app version,
  build, macOS version, CPU architecture, feature area, allowlisted error kind,
  and coarse counts of sessions, panes, and workspace groups.
- Raw error messages and raw `localizedDescription` strings are not safe to
  send by default because they can include paths or user-controlled content.
  The team-diagnostics posture below admits a scrubbed form from the machine
  owner's own errors only; the anonymous tiers never do.
- Feedback reports are separate from product analytics: the user may generate a
  diagnostic summary while analytics is off, but it must appear in an editable
  email draft before anything is sent.

## Anonymous PostHog delivery

For anonymous delivery, awesoMux constructs one HTTPS request per accepted
event against PostHog's
[documented `/i/v0/e/` Capture API](https://posthog.com/docs/api/capture) at the
fixed US Cloud ingestion origin. The origin and path are not user-configurable, and all HTTP
redirects are rejected. There is no PostHog SDK: the transport has no automatic
lifecycle or screen events, swizzling, remote config, feature flags, person
profiles, crash capture, or provider-owned persistent queue. Anonymous
operation never calls `identify`.

The request envelope has a closed shape: project token, allowlisted event name,
app-owned random identifier, timestamp, sanitized typed properties,
`$process_person_profile = false`, and `$geoip_disable = true`. PostHog still
receives ordinary network-layer metadata such as the request source IP, but the
event disables GeoIP enrichment. The PostHog project must also keep GeoIP
enrichment disabled and IP anonymization enabled; this provider-side setting
is a release gate. The transport uses an ephemeral URL session with cookie,
cache, and credential stores disabled.

The app maintains no retry queue. At most four requests may be in flight; an
event above that bound is dropped and recorded as such in the local ledger.
The ledger's `queued` wire value is displayed as **Submitted** and means only
that the request was created and resumed, never that PostHog ingested it. HTTP
failures and non-success responses are recorded in private system logs, not used
to claim delivery. Consent is checked immediately before submission. Consent
withdrawal, a tier downgrade, and explicit analytics-data deletion cancel tracked
requests;
a request already in flight may still reach PostHog. Normal termination drains
the app-owned ledger only and does not delay exit for analytics delivery.

The app-local random analytics identifier is retained when a user turns
analytics off and chooses to keep local data. Explicitly deleting analytics
data removes the local ledger and identifier; the next accepted event mints a
new identifier. Delivery fails closed unless identifier persistence and
owner-only permissions are proven. The ledger intentionally shows the final
sanitized app event properties and submission result, but excludes the random
identifier and transport-only privacy controls so it does not become an
identity store itself.

## Team-diagnostics posture

Maintainers need richer error detail from their own machines to troubleshoot
without weakening the anonymous posture for everyone else. `team_diagnostics`
is a posture layered on top of the consent levels, not a fourth consent
level. It relaxes the raw-description rule for the machine owner's own data
only; the boundary for anonymous users is unchanged.

There is no runtime allowlist of maintainers. The posture is maintainer-only
by convention — it requires hand-editing local config that has no settings UI
and no default-on path — not by enforcement. Someone else who sets these keys
is opting their own machine into sending richer data about itself, a
self-scoped risk. Do not sync or template these keys through dotfiles.

Activation is a single predicate that must be implemented once and shared,
never reimplemented per call site: the posture is active only when the
consent level is `error_reports` or `product_usage`, `team_diagnostics =
true`, and `team_handle` is a valid handle (nonempty, at most 32 characters,
`[a-z0-9_-]` only) in the `[analytics]` config section. The predicate is
evaluated at launch, on every config reload, and again at send time for every
payload — including crash artifacts persisted by a future crash handler from a
previous launch. A payload is sanitized against the tier that holds when it is
submitted, never the tier that held when it was captured; if consent is `off`
at send time, the artifact is not submitted. If any part of the predicate
fails, the standard tier applies
and `identify` is never called. Predicate failure is not silent: the app logs
at startup why the posture is inactive.

When active, error and crash events pass a wider sanitizer tier that admits
named fields only — never a provider-owned metadata dictionary:

- Error domain, error code, and allowlisted error kind.
- Error description strings, only after scrubbing. Path scrubbing is
  necessary but not sufficient for free text: description strings are also
  rejected when they match secret patterns (credentialed URLs, bearer- or
  API-key-shaped tokens).
- Stack traces as structured frames: module name, symbol name, and
  instruction offset from the module load address. Frame fields must
  originate from symbolication of loaded binaries — never from runtime user
  input — and pass the same scrubbing; source-file paths are not admitted.
- Crash payloads only: binary image paths, and only for images inside the
  running app bundle (determined against the live process's bundle path) or
  fixed system locations (`/System`, `/usr/lib`). Qualifying bundle-internal
  paths are transmitted bundle-relative so no user- or volume-specific prefix
  leaves the machine; all other image paths are dropped.

Scrubbing is defined, not aspirational: the sanitizer recognizes absolute
paths in their common forms (`/Users/...`, `/Volumes/...`, `/private/...`,
`/tmp/...`, `file://` URLs, and tilde expansions), rewrites the current
user's home directory to `~`, and rejects any string containing an absolute
path it does not recognize. Rejection omits that field from the event and
records the omission reason in the local analytics event log; the event still
sends with its surviving fields.

Provider payloads are app-constructed: the awesoMux diagnostics boundary
builds and sanitizes the event before the fixed transport receives it, and the
transport accepts no generic provider metadata dictionary. If a future crash
handler persists an artifact before the next launch, that artifact is covered
by this ADR's boundary and is never transmitted or attached anywhere except
through the app sanitizer. The local analytics event log records the final
sanitized app event properties — not an earlier input object — while omitting
the random identifier and transport controls; the implementing issue owns its
retention bounds.

The never-capture list above applies in team mode with exactly the named
admissions of this section — scrubbed description strings and scoped crash
binary images — as its only exceptions. Terminal scrollback, prompt text,
command text, cwd paths, filenames, environment variables, raw config
contents, session titles, workspace group names, screenshots, session replay,
and arbitrary logs stay forbidden in every tier.

Every team-mode event carries super properties `internal_user = true` and
`team_handle`, and a project-level internal-user filter excludes them from
product metrics. That filter is an analytics-view convention, not a storage
partition: anyone with raw project access can query team-mode events, so
project access is scoped accordingly. Team mode uses the same analytics
project as regular users so error signatures group into the same
error-tracking issues. `identify` is permitted only while the activation
predicate holds; regular use never calls `identify`.

Deactivation is idempotent and does not depend on witnessing a transition:
whenever the predicate evaluates false — at launch, on config reload, or on
consent change — tracked team-mode requests are cancelled and app-owned team
annotations cease before any further event is submitted. Deactivation does
not retroactively delete already-sent events; purging them requires a
provider-side deletion request.

## Consequences

Instrumentation work must introduce explicit event/error shapes rather than
shipping generic metadata dictionaries. Any new field that leaves the machine
needs an allowlist decision.

The PostHog project token is necessarily a public client-side ingestion key,
not a secret or authentication control. Ingestion can therefore be spoofed;
maintainers must monitor for abuse and treat analytics as directional evidence,
not an authoritative security or billing signal.

The wider team-diagnostics tier is a separate allowlist, not a relaxation of
the default one. Automatic crash capture — future crash-handler capture whose
payload is still reduced to the named fields above by the app before send —
ships in team mode first. Team-mode validation does not authorize it for
anonymous users: enabling it for `error_reports` users requires a separately
reviewed field allowlist and an amendment to this ADR.

Local provider integrations follow the same explicit-consent posture even when
they do not send data off-machine. OpenCode and Pi plugin installation and
runtime-event acceptance are opt-in under
[ADR 0010](0010-opencode-pi-opt-in-agent-integrations.md).

The support flow can be useful without being silent: "Report a bug" should
generate a user-reviewable email body first, and can later reuse the same
sanitized diagnostic body for a public GitHub issue template when awesoMux is
ready for public issue intake.

PostHog, Sentry, GitHub Issues, or another future provider must all fit this
same boundary. Changing providers does not loosen what awesoMux is allowed to
collect.
