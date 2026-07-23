import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  authorizeNativeCIRequest,
  parseNativeCICommand,
} from "../native-ci-request.mjs";

const validAuthorization = {
  actor: "serabi",
  maintainerLogins: ["serabi", "maintainer-two"],
  repository: "Interactive-Buffoonery/awesomux",
  issueIsPullRequest: true,
  pullRequest: {
    number: 129,
    state: "open",
    draft: false,
    head: {
      sha: "a".repeat(40),
      repo: { full_name: "Interactive-Buffoonery/awesomux" },
    },
  },
};
const requestScript = fileURLToPath(new URL("../native-ci-request.mjs", import.meta.url));
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const nativeRequestWorkflow = readFileSync(
  join(repoRoot, ".github/workflows/native-ci.yml"),
  "utf8",
);
const nativeExecutorWorkflow = readFileSync(
  join(repoRoot, ".github/workflows/native-ci-executor.yml"),
  "utf8",
);
const nativeCleanupWorkflow = readFileSync(
  join(repoRoot, ".github/workflows/native-ci-cleanup.yml"),
  "utf8",
);

test("native CI commands map exact spellings to supported scopes", () => {
  assert.equal(parseNativeCICommand("/ci"), "all");
  assert.equal(parseNativeCICommand("/ci all"), "all");
  assert.equal(parseNativeCICommand("/ci unit"), "unit");
  assert.equal(parseNativeCICommand("/ci adapter"), "adapter");
  assert.equal(parseNativeCICommand("/ci system"), "system");
});

test("native CI rejects alternate spellings and trailing content", () => {
  for (const body of [
    "/CI",
    "/ci ",
    " /ci",
    "/ci\n",
    "/ci full",
    "/ci unit now",
    "/ci adapter\nplease",
  ]) {
    assert.equal(parseNativeCICommand(body), null, body);
  }
});

test("native CI authorization captures an immutable same-repository PR head", () => {
  assert.deepEqual(authorizeNativeCIRequest(validAuthorization), {
    headSHA: "a".repeat(40),
    prNumber: 129,
  });
});

test("native CI authorization rejects untrusted or ineligible requests", () => {
  const cases = [
    ["maintainer", { actor: "outsider" }],
    ["pull request comment", { issueIsPullRequest: false }],
    ["open", { pullRequest: { ...validAuthorization.pullRequest, state: "closed" } }],
    ["draft", { pullRequest: { ...validAuthorization.pullRequest, draft: true } }],
    [
      "same repository",
      {
        pullRequest: {
          ...validAuthorization.pullRequest,
          head: {
            ...validAuthorization.pullRequest.head,
            repo: { full_name: "fork-owner/awesomux" },
          },
        },
      },
    ],
    [
      "40-character",
      {
        pullRequest: {
          ...validAuthorization.pullRequest,
          head: { ...validAuthorization.pullRequest.head, sha: "abc123" },
        },
      },
    ],
  ];

  for (const [message, override] of cases) {
    const request = { ...validAuthorization, ...override };
    assert.throws(() => authorizeNativeCIRequest(request), new RegExp(message));
  }
});

test("native CI request helper exposes parsing and authorization as a CLI", () => {
  const parsed = spawnSync(process.execPath, [requestScript, "parse", "/ci unit"], {
    encoding: "utf8",
  });
  assert.equal(parsed.status, 0);
  assert.equal(parsed.stdout, "unit\n");

  const rejected = spawnSync(process.execPath, [requestScript, "parse", "/ci please"], {
    encoding: "utf8",
  });
  assert.equal(rejected.status, 2);

  const authorized = spawnSync(process.execPath, [requestScript, "authorize"], {
    input: JSON.stringify(validAuthorization),
    encoding: "utf8",
  });
  assert.equal(authorized.status, 0, authorized.stderr);
  assert.deepEqual(JSON.parse(authorized.stdout), {
    headSHA: "a".repeat(40),
    prNumber: 129,
  });
});

test("native preparation exposes exact-pin restore and opt-in save behavior", () => {
  const actionPath = join(repoRoot, ".github/actions/prepare-native/action.yml");
  assert.ok(existsSync(actionPath), "prepare-native action must exist");
  const action = readFileSync(actionPath, "utf8");

  assert.match(action, /save-cache:[\s\S]*?default: "false"/);
  assert.match(action, /cache-namespace:[\s\S]*?default: native-ghostty-v1/);
  for (const output of ["ghostty-sha", "xcode-id", "cache-hit"]) {
    assert.match(action, new RegExp(`^  ${output}:`, "m"));
  }

  assert.match(action, /uses: actions\/cache\/restore@[0-9a-f]{40}/);
  assert.match(action, /uses: actions\/cache\/save@[0-9a-f]{40}/);
  assert.match(action, /working-directory: \$\{\{ github\.workspace \}\}/);
  for (const dimension of [
    "runner.os",
    "runner.arch",
    "ghostty-sha",
    "AWESOMUX_GHOSTTY_OPTIMIZE",
    "swift-pin",
    "xcode-id",
  ]) {
    assert.match(action, new RegExp(dimension.replace(".", "\\.")));
  }
  assert.match(action, /if: steps\.ghostty-cache\.outputs\.cache-hit != 'true'/);
  assert.match(action, /AWESOMUX_GHOSTTY_REQUIRE_PIN_MATCH: "1"/);
  assert.match(action, /run: \.\/script\/ensure_ghostty_artifacts\.sh/);
  assert.match(
    action,
    /if: inputs\.save-cache == 'true' && steps\.ghostty-cache\.outputs\.cache-hit != 'true'/,
  );
  assert.doesNotMatch(action, /^\s+path: \.build\/?$/m);
});

test("Swift CodeQL delegates native preparation to the shared action", () => {
  const workflow = readFileSync(join(repoRoot, ".github/workflows/swift-codeql.yml"), "utf8");

  assert.match(workflow, /uses: \.\/\.github\/actions\/prepare-native/);
  assert.match(workflow, /save-cache: "true"/);
  assert.match(workflow, /languages: swift\n\s+build-mode: manual/);
  assert.match(workflow, /run: swift build --arch arm64/);
  assert.doesNotMatch(workflow, /actions\/cache|brew install|downloadComponent MetalToolchain/);
  assert.doesNotMatch(workflow, /run: \.\/script\/ensure_ghostty_artifacts\.sh/);
});

test("native CI exposes only slash-command and scoped manual triggers", () => {
  const workflowPath = join(repoRoot, ".github/workflows/native-ci.yml");
  assert.ok(existsSync(workflowPath), "native CI workflow must exist");
  const workflow = nativeRequestWorkflow;

  assert.match(workflow, /issue_comment:\n\s+types: \[created\]/);
  assert.match(workflow, /workflow_dispatch:[\s\S]*?scope:[\s\S]*?type: choice/);
  for (const scope of ["all", "unit", "adapter", "system"]) {
    assert.match(workflow, new RegExp(`^\\s+- ${scope}$`, "m"));
  }
  assert.doesNotMatch(workflow, /^\s{2}(?:push|pull_request|schedule):/m);
  assert.doesNotMatch(workflow.split("jobs:")[0], /concurrency:/);
});

test("native CI resolves authorized requests in trusted workflow code", () => {
  const workflow = nativeRequestWorkflow;
  const resolveJob = workflow.match(/\n  resolve:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/)?.[1];
  assert.ok(resolveJob, "native request resolver job must exist");

  assert.match(resolveJob, /permissions:\n\s+actions: write\n\s+contents: write\n\s+issues: write\n\s+pull-requests: write/);
  assert.match(workflow, /MAINTAINER_LOGINS_JSON: \$\{\{ vars\.MAINTAINER_LOGINS_JSON \|\| '\[\]' \}\}/);
  assert.match(workflow, /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/);
  assert.match(workflow, /node \.github\/scripts\/native-ci-request\.mjs parse/);
  assert.match(workflow, /repos\/\$\{GITHUB_REPOSITORY\}\/pulls\/\$\{PR_NUMBER\}/);
  assert.match(workflow, /node \.github\/scripts\/native-ci-request\.mjs authorize/);
  assert.match(workflow, /trusted_sha="\$\(git rev-parse HEAD\)"/);
  assert.match(workflow, /execution_ref="native-ci-runs\/run-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}"/);
  assert.match(workflow, /repos\/\$\{GITHUB_REPOSITORY\}\/git\/refs/);
  assert.match(workflow, /native-ci-executor\.yml\/dispatches/);
  for (const input of [
    "target-sha",
    "pr-number",
    "scope",
    "trusted-sha",
    "execution-ref",
    "trigger",
  ]) {
    assert.match(workflow, new RegExp(`inputs\\[${input}\\]`));
  }
  assert.match(
    workflow,
    /native-ci-executor\.yml\/dispatches[\s\S]*issues\/comments\/\$\{COMMENT_ID\}\/reactions[\s\S]*-f content=eyes/,
  );
});

test("native CI isolates untrusted execution in a disposable branch cache scope", () => {
  assert.match(nativeExecutorWorkflow, /workflow_dispatch:/);
  assert.doesNotMatch(
    nativeExecutorWorkflow,
    /^\s{2}(?:issue_comment|pull_request|pull_request_target|push|schedule):/m,
  );
  assert.match(nativeExecutorWorkflow, /\^native-ci-runs\/run-\[0-9\]\+\-\[0-9\]\+\$/);
  assert.match(nativeExecutorWorkflow, /ACTUAL_REF: \$\{\{ github\.ref \}\}/);
  assert.match(nativeExecutorWorkflow, /ACTUAL_SHA: \$\{\{ github\.sha \}\}/);
  assert.match(nativeExecutorWorkflow, /ACTUAL_REF" != "refs\/heads\/\$EXECUTION_REF/);
  assert.match(nativeExecutorWorkflow, /ACTUAL_SHA" != "\$TRUSTED_SHA/);
  assert.match(nativeExecutorWorkflow, /\.head\.sha == \$targetSHA/);
  assert.doesNotMatch(nativeRequestWorkflow, /Check out captured SHA|\.\/script\/test\.sh/);
});

test("native CI executes captured PR code with read-only permissions and restore-only caching", () => {
  const workflow = nativeExecutorWorkflow;
  const nativeJob = workflow.match(/\n  native:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/)?.[1];
  assert.ok(nativeJob, "native execution job must exist");

  assert.match(nativeJob, /runs-on: \$\{\{ vars\.NATIVE_CI_RUNNER \|\| 'macos-26' \}\}/);
  assert.match(
    nativeJob,
    /group: native-pr-\$\{\{ needs\.resolve\.outputs\.pr-number \|\| github\.run_id \}\}/,
  );
  assert.match(nativeJob, /cancel-in-progress: true/);
  assert.match(nativeJob, /permissions:\n\s+contents: read/);
  assert.doesNotMatch(nativeJob, /checks: write|issues: write|secrets\./);
  assert.match(nativeJob, /ref: \$\{\{ needs\.resolve\.outputs\.target-sha \}\}/);
  assert.match(nativeJob, /submodules: recursive/);
  assert.match(nativeJob, /persist-credentials: false/);
  assert.match(nativeJob, /actual_sha="\$\(git rev-parse HEAD\)"/);
  assert.match(nativeJob, /actual_sha" != "\$EXPECTED_HEAD_SHA/);
  assert.match(nativeJob, /ref: \$\{\{ needs\.resolve\.outputs\.trusted-sha \}\}/);
  assert.match(nativeJob, /path: _trusted/);
  assert.match(nativeJob, /uses: \.\/_trusted\/\.github\/actions\/prepare-native/);
  assert.doesNotMatch(nativeJob, /uses: \.\/\.github\/actions\/prepare-native/);
  assert.match(nativeJob, /save-cache: "false"/);

  assert.match(nativeJob, /\.\/script\/test\.sh "\$GROUP" --xunit-output "\$XUNIT_PATH"/);
  assert.match(nativeJob, /\.build\/test-results\/native-ci\.xml/);
  assert.match(nativeJob, /\.build\/test-results\/native-ci\.log/);
  assert.doesNotMatch(nativeJob, /\.\/script\/build_and_run\.sh --stage-release/);
  assert.match(nativeJob, /uses: actions\/upload-artifact@[0-9a-f]{40}/);
  assert.match(nativeJob, /if: always\(\)/);
  assert.match(nativeJob, /retention-days: 3/);
  for (const field of ["Group", "Exact SHA", "Trigger", "Duration", "Result", "Artifact"]) {
    assert.match(nativeJob, new RegExp(`\\*\\*${field}:\\*\\*`));
  }
});

test("native CI splits scope=all across isolated timing/nontiming test processes", () => {
  const workflow = nativeExecutorWorkflow;
  const resolveJob = workflow.match(/\n  resolve:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/)?.[1];
  const nativeJob = workflow.match(/\n  native:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/)?.[1];
  assert.ok(resolveJob, "native request resolver job must exist");
  assert.ok(nativeJob, "native execution job must exist");

  // Splitting real-blocking-OS-call suites (sockets, subprocesses, file
  // watchers/locks) into their own swift test process keeps them from
  // starving Swift Concurrency's process-wide thread pool for ~4600
  // unrelated tests on a CPU-constrained hosted runner (issue #162).
  assert.match(resolveJob, /groups='\["timing","nontiming"\]'/);
  assert.match(resolveJob, /groups="\[\\"\$SCOPE\\"\]"/);
  assert.match(nativeJob, /strategy:\n\s+fail-fast: false\n\s+matrix:\n\s+group: \$\{\{ fromJson\(needs\.resolve\.outputs\.groups\) \}\}/);
  assert.match(nativeJob, /concurrency:\n\s+group: native-pr-.*-\$\{\{ matrix\.group \}\}/);
  assert.match(nativeJob, /name: native-ci-\$\{\{ matrix\.group \}\}-\$\{\{ needs\.resolve\.outputs\.target-sha \}\}/);
});

test("native release build runs once for scope=all after both test legs succeed", () => {
  const workflow = nativeExecutorWorkflow;
  const releaseJob = workflow.match(
    /\n  native-release-build:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/,
  )?.[1];
  assert.ok(releaseJob, "native release build job must exist");

  assert.match(releaseJob, /needs: \[resolve, native\]/);
  assert.match(releaseJob, /if: needs\.resolve\.outputs\.scope == 'all' && needs\.native\.result == 'success'/);
  assert.match(releaseJob, /runs-on: \$\{\{ vars\.NATIVE_CI_RUNNER \|\| 'macos-26' \}\}/);
  assert.match(releaseJob, /permissions:\n\s+contents: read/);
  assert.doesNotMatch(releaseJob, /checks: write|issues: write|secrets\./);
  assert.match(releaseJob, /uses: \.\/_trusted\/\.github\/actions\/prepare-native/);
  assert.match(releaseJob, /\.\/script\/build_and_run\.sh --stage-release/);
  assert.match(releaseJob, /codesign --verify --deep --strict/);
  assert.match(releaseJob, /Signature=adhoc/);
});

test("native CI never pre-seeds and mistake-preserves an xUnit failure", () => {
  const workflow = nativeExecutorWorkflow;
  const initializeStep = workflow.match(
    /- name: Initialize native results\n([\s\S]*?)(?=\n\s+- name:)/,
  )?.[1];
  const executeStep = workflow.match(
    /- name: Run native validation\n([\s\S]*?)(?=\n\s+- name:)/,
  )?.[1];
  assert.ok(initializeStep, "native result initialization step must exist");
  assert.ok(executeStep, "native execution step must exist");

  assert.doesNotMatch(initializeStep, /native-ci\.xml|<testsuites/);
  assert.match(executeStep, /if \[\[ ! -s "\$XUNIT_PATH" \]\]; then/);
  assert.match(executeStep, /<testsuites tests="1" failures="1">/);
  assert.match(executeStep, /Native validation did not produce an xUnit report\./);
});

test("native CI reporting is isolated from pull request execution", () => {
  const workflow = nativeExecutorWorkflow;
  const reportJob = workflow.match(/\n  report:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/)?.[1];
  assert.ok(reportJob, "trusted reporting job must exist");

  assert.match(reportJob, /needs: \[resolve, native, native-release-build\]/);
  assert.match(reportJob, /if: always\(\)/);
  assert.match(reportJob, /permissions:\n\s+checks: write/);
  assert.doesNotMatch(reportJob, /actions\/checkout|\.\/script\/|secrets\.|contents: write|issues: write/);
  assert.match(reportJob, /name="Native CI"/);
  assert.match(reportJob, /EXACT_SHA: \$\{\{ inputs\.target-sha \}\}/);
  assert.match(reportJob, /RESOLVE_JOB_RESULT: \$\{\{ needs\.resolve\.result \}\}/);
  // Job-level needs.<job>.result aggregates correctly across a matrix's
  // legs; the per-leg custom `outputs.result` does not (last-writer-wins),
  // so the pass/fail gate must not depend on needs.native.outputs.result.
  assert.match(reportJob, /NATIVE_JOB_RESULT: \$\{\{ needs\.native\.result \}\}/);
  assert.doesNotMatch(reportJob, /\w+: \$\{\{ needs\.native\.outputs\.result \}\}/);
  assert.match(reportJob, /RELEASE_BUILD_JOB_RESULT: \$\{\{ needs\['native-release-build'\]\.result \}\}/);
  assert.match(reportJob, /head_sha="\$EXACT_SHA"/);
  assert.match(reportJob, /status=completed/);
  assert.match(reportJob, /conclusion="\$conclusion"/);
  assert.match(reportJob, /ARTIFACT_URL: \$\{\{ needs\.native\.outputs\.artifact-url \}\}/);
});

test("native CI explicitly dispatches isolated execution-ref cleanup", () => {
  const cleanupDispatchJob = nativeExecutorWorkflow.match(
    /\n  cleanup:\n([\s\S]*?)(?=\n  [a-z][a-z-]*:\n|$)/,
  )?.[1];
  assert.ok(cleanupDispatchJob, "trusted cleanup dispatch job must exist");

  assert.match(cleanupDispatchJob, /needs: \[resolve, native, native-release-build, report\]/);
  assert.match(cleanupDispatchJob, /if: always\(\)/);
  assert.match(cleanupDispatchJob, /permissions:\n\s+actions: write/);
  assert.match(cleanupDispatchJob, /native-ci-cleanup\.yml\/dispatches/);
  assert.match(cleanupDispatchJob, /inputs\[execution-ref\]/);
  assert.match(cleanupDispatchJob, /ACTUAL_REF: \$\{\{ github\.ref \}\}/);
  assert.match(cleanupDispatchJob, /ACTUAL_SHA: \$\{\{ github\.sha \}\}/);
  assert.doesNotMatch(
    cleanupDispatchJob,
    /actions\/checkout|\.\/script\/|secrets\.|contents: write|checks: write|issues: write/,
  );

  assert.match(nativeCleanupWorkflow, /workflow_dispatch:[\s\S]*execution-ref:/);
  assert.match(nativeCleanupWorkflow, /permissions:\n\s+contents: write/);
  assert.match(nativeCleanupWorkflow, /\^native-ci-runs\/run-\[0-9\]\+\-\[0-9\]\+\$/);
  assert.match(nativeCleanupWorkflow, /git\/refs\/heads\/\$\{EXECUTION_REF\}/);
  assert.doesNotMatch(nativeCleanupWorkflow, /actions\/checkout|\.\/script\/|secrets\./);
});
