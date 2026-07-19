# Continuous integration

This is the current reference for awesoMux CI. The repository separates fast
merge gates, advisory native validation, and security analysis so pull requests
receive quick deterministic feedback without executing untrusted code with a
write-capable token.

## Pull-request checks

The `Require fast CI` repository ruleset requires these stable check names:

- `Fast deterministic guards` runs the Linux source-policy, review-automation,
  localization, test-wait, toolchain, and changed-line formatting checks.
- `CodeQL interpreted complete` aggregates the automatic Actions and Python
  CodeQL analyses.
- `Validate PR metadata` validates the pull-request template and metadata from
  trusted default-branch workflow code. Dependabot pull requests skip this
  human-authored description check because GitHub owns their generated bodies.

The ruleset does not require a branch to be up to date before merging. Other
checks, including tint contrast, pull-request sizing, automated review, and
native CI, remain useful but advisory.

The strongest pre-PR gate remains local:

```sh
./script/preflight.sh
```

It runs the fast guards, the complete Swift suite, and the existing staged-app
build, signing, and launch verification. Run focused native groups with:

```sh
./script/test.sh unit
./script/test.sh adapter
./script/test.sh system
./script/test.sh all
```

## Advisory native CI

On an open, non-draft, same-repository pull request, a login listed in the
`MAINTAINER_LOGINS_JSON` Actions variable may post one of these exact comments:

| Command | Validation |
| --- | --- |
| `/ci` | Full test suite and release-unsigned, ad-hoc-signed staged app build |
| `/ci all` | Full test suite and release-unsigned, ad-hoc-signed staged app build |
| `/ci unit` | Unit test group |
| `/ci adapter` | Adapter test group |
| `/ci system` | System test group |

Capitalization changes, leading or trailing whitespace, extra lines, and any
other arguments are rejected. The workflow reacts with eyes only after the
request is authorized.

Each accepted comment captures the pull request's current 40-character head
SHA. The request dispatcher creates a unique execution ref at the captured
trusted default-branch commit, then starts the native executor from that ref.
The executor confirms that the pull request is still eligible and still points
to the captured SHA before running. The native job checks out that SHA
recursively, verifies `HEAD` still matches it, and reports a `Native CI` check
on that exact commit. A later commit does not inherit the result; request a
fresh run with a new comment. A newer accepted request for the same pull request
cancels the older native job.

Maintainers may also dispatch the workflow manually and select `all`, `unit`,
`adapter`, or `system`. Manual dispatches validate the selected default-branch
SHA. They are restore-only and do not populate caches.

The `all` scope runs the existing interfaces rather than introducing another
build system:

```sh
./script/test.sh all
./script/build_and_run.sh --stage-release
codesign --verify --deep --strict --verbose=2 dist/awesoMux.app
```

The workflow also confirms that the staged app has an ad-hoc signature. It does
not launch the GUI, alter release signing, or run the signed/notarized release
workflow.

## Trust boundaries

Native CI splits request handling, code execution, reporting, and cleanup across
trusted and untrusted workflow contexts:

1. The request workflow checks out trusted default-branch code, validates the
   command and actor, reads pull-request metadata, and captures the immutable
   SHA. It creates a unique execution ref pointing at that trusted commit,
   dispatches the executor, and only then adds the eyes reaction. Its write
   permissions are confined to dispatching the executor, managing that ref, and
   writing the reaction; it never checks out or executes pull-request code.
2. The executor starts in the unique execution-ref context and verifies the ref,
   trusted commit, current pull-request eligibility, and unchanged head SHA.
   The disposable ref is the cache security boundary: even pull-request code
   that directly abuses the Actions cache service token cannot write into the
   default-branch cache scope.
3. The native job executes the captured pull-request code with only
   `contents: read`. Checkout credentials are not persisted, and the job has no
   secrets or write-capable token. Native preparation is loaded from the exact
   trusted helper SHA captured by the resolver, not from the pull-request tree.
4. The reporter does not check out or execute pull-request code. It receives
   only the captured metadata and native result and uses `checks: write` to
   publish the completed `Native CI` check.
5. After execution and reporting finish, a trusted final executor job explicitly
   dispatches the isolated cleanup workflow. Cleanup deletes only the exact ref
   in the `native-ci-runs/run-...` namespace; neither job downloads artifacts or
   executes pull-request code.

OpenCode review uses a different passive-data boundary and never executes pull
request code. See [`code-review.md`](code-review.md).

## Native preparation and caching

The shared `.github/actions/prepare-native` action assumes the caller has
already checked out the exact target. It reads the committed Ghostty gitlink and
the active Xcode identity, then restores `.build/ghostty` with a cache key that
includes:

- cache namespace;
- operating system and architecture;
- Ghostty SHA and optimize mode;
- pinned Swift version; and
- Xcode version and build identity.

On a miss, the action installs pinned Zig and the Metal toolchain as needed,
then runs `script/ensure_ghostty_artifacts.sh` with exact-pin enforcement. There
is no general `.build` cache.

Slash-command and native `workflow_dispatch` runs are restore-only at the
action level and execute in a unique disposable branch cache scope. This second
boundary matters because a process running in an Actions job can access the
cache service token even when the workflow never invokes a save action. The
trusted weekly/manual Swift CodeQL workflow may save a newly built Ghostty
artifact cache. The signed release workflow keeps its existing provisioning
and cache behavior.

## Results and artifacts

Every native job uploads `.build/test-results/` for three days. The artifact
contains:

- `native-ci.xml`, an xUnit report from the selected test group or an explicit
  infrastructure failure report; and
- `native-ci.log`, the captured test, staging, and signature output.

The Actions summary records the scope, exact SHA, trigger, duration, result, and
artifact link. Native CI is advisory; failures should still be investigated and
classified as product/test, runner, or workflow infrastructure failures.

## CodeQL policy

Actions and Python CodeQL run automatically on pull requests and `main`. Their
aggregate `CodeQL interpreted complete` check does not wait for Swift.

Swift CodeQL runs on `macos-26` (or `NATIVE_CI_RUNNER`) every Tuesday at
`17 8 * * 2` and through manual dispatch. It retains manual-build analysis and
the committed Ghostty exact-pin preparation, but does not run on pull requests
or every `main` push.

## Rollout status

Automatic native execution on `main` and the daily native canary are not yet
enabled. Before enabling them, the manual workflow must produce five consecutive
successful full runs covering at least three distinct pull-request head SHAs,
including one during ordinary concurrent repository activity. Those runs must
need no retries, blanket serialization, or timeout increases; their xUnit
artifacts must contain the complete suite; and their staged app and signature
checks must pass.

A deterministic product or test defect restarts that count after a focused fix.
Native CI remains advisory after canaries are enabled. Making it a required
merge check requires a separate reliability review.

## Troubleshooting

- No eyes reaction: confirm the comment is an exact supported command, the pull
  request is open and non-draft, the head repository matches this repository,
  and the actor is present in `MAINTAINER_LOGINS_JSON`.
- A result belongs to an older SHA: post a fresh command after the latest commit.
- Preparation is slow: inspect the action log for the cache key and cache-hit
  output. A miss intentionally rebuilds exact-pin Ghostty artifacts.
- An execution ref remains after a run: inspect `Native CI execution-ref
  cleanup`. The ref name must be under `native-ci-runs/run-`; do not delete
  unrelated branches.
- Tests fail: download the short-lived xUnit and log artifact before rerunning.
  Do not add blanket retries or increase the timeout to hide a failure.
- The staged build fails: reproduce with `./script/build_and_run.sh
  --stage-release` and verify `dist/awesoMux.app` with `codesign` locally.
- A required check is missing: confirm its stable job name and the separate
  `Require fast CI` ruleset; do not modify the existing `Protect main` ruleset.
