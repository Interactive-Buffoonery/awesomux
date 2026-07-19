# 0009 — PostHog opt-in for macOS error reporting

- **Status:** Accepted
- **Date:** 2026-05-17
- **Amended:** 2026-07-18
- **Deciders:** Sarah

## Context

awesoMux needs better visibility into real-world macOS crashes and handled app
errors, but terminal users have a higher-than-normal privacy expectation. The
project also expects a future iOS app, but the iOS analytics design is not ready
and should not be implicitly decided by the macOS implementation.

PostHog is attractive because it can cover error tracking now and product
analytics later in one open-source-friendly system. Sentry remains the more
specialized error-tracking product, so the choice has to preserve error quality
rather than treating analytics as a substitute for crash diagnostics.

## Decision

Use PostHog as the intended first provider for **macOS** opt-in error
reporting, subject to ADR-0008's privacy boundary.

The macOS settings model should support all three analytics consent levels from
the start:

- `off`
- `error_reports`
- `product_usage`

The launch implementation may wire only `off` and `error_reports`. The
`product_usage` level exists in the model so later product-shape analytics do
not require another schema turn, but no product-usage event is allowed until an
explicit event allowlist exists.

PostHog must be configured for privacy-first macOS use:

- Start opted out unless the user explicitly chooses a non-`off` level.
- Keep identity anonymous by default; do not call `identify` for normal use.
- Submit app-constructed envelopes directly to the fixed US Cloud Capture API;
  do not add the PostHog SDK while the direct transport meets the requirement.
- Reject redirects and use no provider-owned persistence or retry queue.
- Set `$process_person_profile = false` and `$geoip_disable = true` on every
  request, while retaining the project-side privacy settings in ADR-0008.
- Keep automatic screen/lifecycle capture, remote config, feature flags,
  session replay, screenshots, log capture, terminal content capture, and
  network telemetry absent.
- Use manual, sanitized error capture for handled app errors.
- Evaluate automatic crash capture with a spike before relying on it.

Before shipping, perform a macOS error-reporting spike that proves PostHog can
produce actionable symbolicated Swift/macOS crash reports for awesoMux. If that
spike fails, revisit Sentry or another dedicated crash provider for the
`error_reports` tier without changing the consent model.

## Consequences

The macOS app can add useful crash/error visibility while keeping the default
open-source posture: no background reporting unless the user opts in.

Implementation should isolate analytics behind an app-owned diagnostics service
so the rest of the code reports `error_kind` and sanitized context, not
PostHog-specific dictionaries.

This ADR does not decide the iOS app's analytics behavior. The iOS app may
reuse the same privacy terms and consent levels later, but it needs its own
decision once the mobile product surface, App Store privacy labels, onboarding,
and any mobile-specific PostHog features are understood.
