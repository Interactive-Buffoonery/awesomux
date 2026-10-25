# While-you-were-away summary (#792)

The existing main-actor attention journal owns the departure checkpoint.
Authenticated Companion requests qualify the current interval immediately after
authorization, before response capture or delivery can suspend. Lock and console
session notifications delimit the interval; app activation releases its pending
presentation. Repeated notifications preserve the checkpoint. Device alert
preferences and foreground suppression do not filter this Mac summary.

Each returned interval derives at most 512 journal changes. Undismissed intervals
merge into a bounded presentation, excluding events between away intervals.
Truncation explicitly shows “Older activity unavailable”. Details group stable
workspace/pane IDs, retain deleted targets, and combine attention changes by
attention ID so resolutions are marked. Command facts remain independent.
Nothing is persisted, acknowledged, or selected by reading the summary.

Failure scenarios were written before production changes in the existing local
API E2E executable: pre-departure and post-return authentication, duplicate
notifications, activation ordering, multiple intervals, empty activity, device
suppression, overflow, resolution identity, and journal replacement.

```sh
process-gate -- swift run local-api-e2e --command-attention-only /tmp/while-away-792-run
```

This runs the existing authenticated local socket command journeys plus the
store/journal away scenarios and writes `command-attention.json` and
`while-away.json`. For only the away scenarios, use `--while-away-only`.
The away scenarios directly drive the store boundary; they do not simulate
Companion TLS authentication, actual macOS lock notifications, or native UI.

Native acceptance still needs an authenticated paired phone during a real lock
or switched-user interval, both activation/return orderings, no qualifying phone
activity, deleted targets, multiple intervals, overflow, banner dismissal,
keyboard navigation, VoiceOver, window resizing, and light/dark appearance.
Run those only with an owned app/profile under process-gate; keep existing
Accessibility/Screen Recording grants and clean up only owned processes.
