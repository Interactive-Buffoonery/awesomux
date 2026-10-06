# Queued remote Markdown admission failure modes

Written before the queued-admission implementation. A narrow isolation proof is
necessary because the race depends on deliberately holding a predecessor fetch
and joining a cohort during its rejection decision. UI timing cannot reliably
exercise these transitions, and no repository unit suite is added.

The repeatable script `script/verify_remote_markdown_admission.py` extracts the
actual fetch coordinator into a temporary Swift Testing package. Resource and
outcome values are stand-ins; permitted operations run a counted real subprocess
and write a counted cache artifact. This is isolated coordinator evidence, not
an actual SSH connection or rendered app E2E proof.

Failure modes checked:

1. The sole queued origin disappears: zero subprocesses and cache writes.
2. Every coalesced origin disappears: zero subprocesses and cache writes.
3. The leader cancels, but a follower remains valid: exactly one operation.
4. A valid follower registers while invalid predicates are evaluated: retry the
   decision after the cohort revision changes; callbacks must run outside locks.
5. A refused cohort is replaced: an old completion must not remove the newer
   generation, and a later follower must still join that replacement.
6. The origin changes after transport starts: one operation may complete, but
   the originating caller must reject display. Existing routing suites exercise
   the production post-fetch validator; the harness checks the boundary model.

Admission after queued predecessors is the operation-start linearization point.
It does not claim an atomic boundary with the operating system's process launch.

## Coalesced outcome ownership fault scenario

Recorded before the outcome-claim change: a queued read's loading owner becomes
stale or cancelled, while a valid follower opens the already-selected remote
resource. The follower admits the read but has no loading ownership, and the
document group suppresses its same-resource now-showing cue. A successful result
or failure therefore needs a distinct once-per-workspace outcome claim after
live validation. A valid follower must claim once; repeated claims in that
workspace must fail, while another workspace may independently claim its cue.

Unavailable-result fault recorded before its routing adjustment: a stale document
failure presenter remains counted in the cohort, while a valid explicit Refresh
receives no saved result. Static presenter counts must not silence that Refresh.
The first live eligible consumer claims the unavailable cue once, with Refresh
retaining its visible stale banner and later document popups suppressed. Quiet
restore keeps its existing deferral policy. The isolated claim scenario covers
both a saved result and nil; existing routing fixtures verify nil speech counts.
