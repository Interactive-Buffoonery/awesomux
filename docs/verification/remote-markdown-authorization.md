# Remote Markdown authorization registry proof

Failure modes recorded before changing the registry:

1. A token is consumed twice or used after result validation or discard.
2. Missing or changed origin permits a fetch or display, including a changed
   terminal plan, runtime SSH observation, document policy, or association.
3. A saved document reads a sibling terminal's destination, or a restrictive
   saved document bypasses confirmation or confirms a different destination.
4. Abandoned authorized records grow without bound.
5. Abandoned fetching records survive forever and escape the same bound.
6. Eviction renews an old token, evicts a newer record first, or lets an evicted
   fetching record validate its result.
7. Completed/discarded records leave an unbounded ordering ledger or cause
   normal subsequent reads to fail.

The repeatable `script/verify_remote_markdown_authorization.py` creates a
temporary Swift Testing package. It copies the actual production authorization
service unchanged and imports the repository's actual `AwesoMuxCore` product
and its bridge models. No model stand-ins or repository unit tests are added.
The proof checks public authorization behavior and inspects retained collection
counts to verify the bound. It performs no SSH, file-read UI, or rendered app
E2E; its report is isolated authorization evidence.

The registry retains at most 512 total authorized/fetching attempts in original
registration order. Registering the next attempt evicts the oldest record,
regardless of its stage. Evicted tokens fail closed: they cannot start a read
or validate a result and require a new authorization. There is no time-based
expiry, reusable connection grant, or persistence. Completed/discarded entries
also leave the ordering ledger. The cap accommodates normal concurrent reads
while bounding abandoned operations.

Run `python3 script/verify_remote_markdown_authorization.py`. The default report
is `.build/verification/remote-markdown-authorization.log`; use `--output` to
choose another artifact path. SwiftPM builds the real core dependency graph in
the temporary package, so its first run may require dependency downloads.
