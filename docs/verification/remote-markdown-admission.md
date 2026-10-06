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
