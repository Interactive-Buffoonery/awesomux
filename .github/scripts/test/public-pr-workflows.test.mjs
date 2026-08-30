import test from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const read = (path) => readFileSync(join(repoRoot, path), "utf8");

const workflows = {
  cheapGuards: read(".github/workflows/cheap-guards.yml"),
  codeql: read(".github/workflows/codeql.yml"),
  dependabot: read(".github/dependabot.yml"),
  native: read(".github/workflows/native-ci.yml"),
  nativeExecutor: read(".github/workflows/native-ci-executor.yml"),
  size: read(".github/workflows/pr-size.yml"),
  swiftCodeql: read(".github/workflows/swift-codeql.yml"),
  template: read(".github/workflows/pr-template.yml"),
  tintContrast: read(".github/workflows/tint-contrast.yml"),
};
const ensureRepositoryLabel = join(repoRoot, ".github/scripts/ensure-repository-label.sh");

function runEnsureRepositoryLabel({
  lookupError = "",
  lookupResponse,
  lookupSequence,
  lookupStatus = 200,
  lookupWarning = "",
  postError = "",
  postResponse = "",
  postStatus = 201,
}) {
  const fixture = mkdtempSync(join(tmpdir(), "awesomux-label-test-"));
  const calls = join(fixture, "calls");
  const lookupState = join(fixture, "lookup-state");
  const mockGh = join(fixture, "gh");
  const lookupSequenceJson = JSON.stringify(
    lookupSequence ?? [
      {
        error: lookupError,
        response: lookupResponse ?? "",
        status: lookupStatus,
        warning: lookupWarning,
      },
    ],
  );
  const script = `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$GH_CALLS"
if [[ "$1" == "api" && "\${2:-}" == "--include" && "\${3:-}" == "--method" && "\${4:-}" == "POST" ]]; then
    printf 'HTTP/2.0 %s Synthetic\\r\\n' "$GH_POST_STATUS"
    printf 'Content-Type: application/json\\r\\n\\r\\n'
    printf '%s\\n' "$GH_POST_RESPONSE"
    if [[ -n "\${GH_POST_ERROR:-}" ]]; then
        printf '%s\\n' "$GH_POST_ERROR" >&2
    fi
    if [[ "$GH_POST_STATUS" -ge 400 ]]; then
        exit 1
    fi
    exit 0
fi
if [[ "$1" == "api" && "\${2:-}" == "--include" ]]; then
    lookup_index="$(cat "$GH_LOOKUP_STATE")"
    lookup_count="$(jq 'length' <<<"$GH_LOOKUP_SEQUENCE")"
    if (( lookup_index >= lookup_count )); then
        echo "unexpected label lookup call" >&2
        exit 1
    fi
    lookup_status="$(jq -r --argjson index "$lookup_index" '.[$index].status' <<<"$GH_LOOKUP_SEQUENCE")"
    lookup_response="$(jq -r --argjson index "$lookup_index" '.[$index].response' <<<"$GH_LOOKUP_SEQUENCE")"
    lookup_error="$(jq -r --argjson index "$lookup_index" '.[$index].error // ""' <<<"$GH_LOOKUP_SEQUENCE")"
    lookup_warning="$(jq -r --argjson index "$lookup_index" '.[$index].warning // ""' <<<"$GH_LOOKUP_SEQUENCE")"
    echo "$((lookup_index + 1))" >"$GH_LOOKUP_STATE"
    printf 'HTTP/2.0 %s Synthetic\\r\\n' "$lookup_status"
    printf 'Content-Type: application/json\\r\\n\\r\\n'
    printf '%s\\n' "$lookup_response"
    if [[ -n "$lookup_warning" ]]; then
        printf '%s\\n' "$lookup_warning" >&2
    fi
    if [[ "$lookup_status" -ge 400 ]]; then
        printf '%s\\n' "$lookup_error" >&2
        exit 1
    fi
    exit 0
fi
if [[ "$1" == "api" && "\${2:-}" == "--method" && "\${3:-}" == "PATCH" ]]; then
    exit 0
fi
`;

  writeFileSync(mockGh, script);
  chmodSync(mockGh, 0o755);
  writeFileSync(lookupState, "0");

  const result = spawnSync(
    "bash",
    [ensureRepositoryLabel, "Interactive-Buffoonery/awesomux", "size:S", "5ebd3e", "10-29 effective changed lines."],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        GH_CALLS: calls,
        GH_LOOKUP_SEQUENCE: lookupSequenceJson,
        GH_LOOKUP_STATE: lookupState,
        GH_POST_ERROR: postError,
        GH_POST_RESPONSE: postResponse,
        GH_POST_STATUS: String(postStatus),
        PATH: `${fixture}:${process.env.PATH}`,
      },
    },
  );
  const recordedCalls = existsSync(calls) ? readFileSync(calls, "utf8") : "";
  rmSync(fixture, { recursive: true, force: true });
  return { ...result, recordedCalls };
}

function assertMetadataOnly(name, workflow) {
  assert.match(workflow, /pull_request_target:/, `${name} must run trusted base workflow code`);
  assert.match(
    workflow,
    /runs-on: ubuntu-latest/,
    `${name} must use a standard GitHub-hosted runner`,
  );
  assert.doesNotMatch(
    workflow,
    /ref:\s*\$\{\{[^\n]*pull_request\.head/,
    `${name} must not check out a pull request head`,
  );
  assert.doesNotMatch(
    workflow,
    /^\s+(?:npm|pnpm|yarn|bun|swift|zig)\s+(?:install|run|test|build)|^\s+\.\/script\//m,
    `${name} must not execute pull request code or dependencies`,
  );
}

function assertMatchingCodeQLActionPins(name, workflow) {
  const actions = [
    ...workflow.matchAll(/github\/codeql-action\/(init|analyze)@([0-9a-f]{40})/g),
  ];
  assert.deepEqual(
    actions.map((match) => match[1]).sort(),
    ["analyze", "init"],
    `${name} must initialize and analyze CodeQL`,
  );
  assert.equal(
    new Set(actions.map((match) => match[2])).size,
    1,
    `${name} must use one CodeQL action version`,
  );
}

test("all contributor workflows preserve the metadata-only trust boundary", () => {
  for (const [name, workflow] of Object.entries({
    size: workflows.size,
    template: workflows.template,
  })) {
    assertMetadataOnly(name, workflow);
  }
});

test("PR sizing uses a verified passive ref and effective line rules", () => {
  const workflow = workflows.size;
  assert.match(workflow, /runs-on: ubuntu-latest/);
  assert.match(workflow, /head_ref="refs\/remotes\/pull\/\$\{PR_NUMBER\}\/head"/);
  assert.match(workflow, /refs\/pull\/\$\{PR_NUMBER\}\/head:\$\{head_ref\}/);
  assert.match(workflow, /fetched_sha[\s\S]*?PR_HEAD_SHA/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ github\.token \}\}/);
  assert.match(workflow, /pull-requests: write/);
  assert.match(workflow, /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/);
  assert.match(workflow, /credential\.helper=!f\(\)/);
  assert.doesNotMatch(workflow, /extraheader|base64/);
  assert.match(workflow, /git diff --numstat --ignore-all-space --ignore-blank-lines/);
  assert.match(workflow, /vendor\/ghostty\/\*/);
  assert.match(workflow, /if \[\[ "\$non_test_changed" -eq 0 \]\]/);
  assert.match(workflow, /<!-- awesomux-pr-size-xxl -->/);
  assert.match(workflow, /issues\/comments\/\$\{comment_id\}/);
});

test("PR sizing delegates label reconciliation to the tested helper", () => {
  const workflow = workflows.size;
  assert.match(workflow, /\.\/\.github\/scripts\/ensure-repository-label\.sh/);
  assert.doesNotMatch(workflow, /label_response|HTTP 404/);
});

test("a missing repository label is created from its HTTP status", () => {
  const result = runEnsureRepositoryLabel({
    lookupError: "error wording is intentionally unstructured",
    lookupResponse: JSON.stringify({ status: "404" }),
    lookupStatus: 404,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.recordedCalls, /api --include --method POST repos\/Interactive-Buffoonery\/awesomux\/labels/);
});

test("a concurrent duplicate label creation retries lookup and reconciles metadata", () => {
  const result = runEnsureRepositoryLabel({
    lookupSequence: [
      {
        error: "label not found",
        response: JSON.stringify({ status: "404" }),
        status: 404,
      },
      {
        response: JSON.stringify({
          color: "ffffff",
          description: "10-29 effective changed lines.",
        }),
        status: 200,
      },
    ],
    postError: "gh: Validation Failed (HTTP 422)",
    postResponse: JSON.stringify({
      message: "Validation Failed",
      errors: [{ resource: "Label", code: "already_exists", field: "name" }],
    }),
    postStatus: 422,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.recordedCalls, /api --include --method POST repos\/Interactive-Buffoonery\/awesomux\/labels/);
  assert.match(
    result.recordedCalls,
    /api --include repos\/Interactive-Buffoonery\/awesomux\/labels\/size%3AS[\s\S]*api --method PATCH repos\/Interactive-Buffoonery\/awesomux\/labels\/size%3AS/,
  );
});

test("a concurrent duplicate with current metadata needs no patch", () => {
  const result = runEnsureRepositoryLabel({
    lookupSequence: [
      {
        error: "label not found",
        response: JSON.stringify({ status: "404" }),
        status: 404,
      },
      {
        response: JSON.stringify({
          color: "5ebd3e",
          description: "10-29 effective changed lines.",
        }),
        status: 200,
      },
    ],
    postError: "gh: Validation Failed (HTTP 422)",
    postResponse: JSON.stringify({
      message: "Validation Failed",
      errors: [{ resource: "Label", code: "already_exists", field: "name" }],
    }),
    postStatus: 422,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.recordedCalls, /api --include --method POST/);
  assert.doesNotMatch(result.recordedCalls, /--method PATCH/);
});

test("a label creation failure other than already_exists is surfaced", () => {
  const result = runEnsureRepositoryLabel({
    lookupError: "label not found",
    lookupResponse: JSON.stringify({ status: "404" }),
    lookupStatus: 404,
    postError: "gh: Validation Failed (HTTP 422)",
    postResponse: JSON.stringify({
      message: "Validation Failed",
      errors: [{ resource: "Label", code: "invalid", field: "color" }],
    }),
    postStatus: 422,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /label creation failed with HTTP 422/);
  assert.doesNotMatch(result.recordedCalls, /--method PATCH/);
});

test("a temporary label lookup failure is surfaced without a write", () => {
  const result = runEnsureRepositoryLabel({
    lookupError: "temporary upstream failure",
    lookupResponse: JSON.stringify({ status: "503" }),
    lookupStatus: 503,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /label lookup failed with HTTP 503/);
  assert.doesNotMatch(result.recordedCalls, /--method (?:POST|PATCH)/);
});

test("successful label JSON stays separate from gh warnings", () => {
  const result = runEnsureRepositoryLabel({
    lookupResponse: JSON.stringify({
      color: "5ebd3e",
      description: "10-29 effective changed lines.",
    }),
    lookupWarning: "gh: warning: synthetic notice",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /synthetic notice/);
  assert.doesNotMatch(result.recordedCalls, /--method (?:POST|PATCH)/);
});

test("changed repository label metadata is updated", () => {
  for (const lookupResponse of [
    { color: "ffffff", description: "10-29 effective changed lines." },
    { color: "5ebd3e", description: "stale description" },
  ]) {
    const result = runEnsureRepositoryLabel({
      lookupResponse: JSON.stringify(lookupResponse),
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.recordedCalls,
      /api --method PATCH repos\/Interactive-Buffoonery\/awesomux\/labels\/size%3AS/,
    );
    assert.doesNotMatch(result.recordedCalls, /--method POST/);
  }
});

test("hosted native CI stays advisory and maintainer-triggered", () => {
  assert.match(workflows.native, /issue_comment:\n\s+types: \[created\]/);
  assert.match(workflows.native, /workflow_dispatch:/);
  assert.doesNotMatch(workflows.native, /^\s{2}(?:push|pull_request|schedule):/m);
  assert.match(workflows.nativeExecutor, /workflow_dispatch:/);
  assert.doesNotMatch(
    workflows.nativeExecutor,
    /^\s{2}(?:issue_comment|push|pull_request|pull_request_target|schedule):/m,
  );
});

test("fast required checks have stable names", () => {
  assert.match(workflows.cheapGuards, /name: Fast deterministic guards/);
  assert.match(workflows.codeql, /name: CodeQL interpreted complete/);
  assert.match(workflows.template, /name: Validate PR metadata/);
});

test("cheap guards reject stale Ghostty license pins", () => {
  assert.match(workflows.cheapGuards, /\.\/script\/test-ghostty-license-pins\.sh/);
  assert.match(workflows.cheapGuards, /\.\/script\/check_ghostty_license_pins\.sh/);
});

test("interpreted CodeQL stays automatic without waiting for Swift", () => {
  const workflow = workflows.codeql;
  assertMatchingCodeQLActionPins("interpreted CodeQL", workflow);
  assert.match(workflow, /push:\n\s+branches: \[main\]/);
  assert.match(workflow, /pull_request:\n\s+branches: \[main\]/);
  assert.match(workflow, /matrix:\n\s+language: \[actions\]/);
  assert.doesNotMatch(workflow, /python/);
  assert.doesNotMatch(workflow, /schedule:|workflow_dispatch:|Analyze \(swift\)|needs: \[[^\]]*swift/);
});

test("tint contrast fails closed when the Swift filter selects no tests", () => {
  const workflow = workflows.tintContrast;
  assert.match(
    workflow,
    /concurrency:\n\s+group: tint-contrast-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}/,
  );
  assert.match(workflow, /cancel-in-progress: true/);
  assert.match(workflow, /swift-test\.sh --filter SidebarTintContrastTests 2>&1 \| tee/);
  assert.match(
    workflow,
    /grep -Eq 'Test run with \[1-9\]\[0-9\]\* tests\( in \[1-9\]\[0-9\]\* suites\?\)\? passed'/
  );
  assert.match(workflow, /Sidebar tint contrast filter ran no tests/);
  assert.match(workflow, /exit 1/);
});

test("Swift CodeQL is weekly and manual only", () => {
  const workflow = workflows.swiftCodeql;
  assertMatchingCodeQLActionPins("Swift CodeQL", workflow);
  assert.match(workflow, /schedule:\n\s+- cron: "17 8 \* \* 2"/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /^\s{2}(?:push|pull_request):/m);
  assert.match(workflow, /runs-on: \$\{\{ vars\.NATIVE_CI_RUNNER \|\| 'macos-26' \}\}/);
  assert.match(workflow, /permissions:\n\s+contents: read\n\s+security-events: write/);
  assert.match(workflow, /uses: \.\/\.github\/actions\/prepare-native/);
  assert.match(workflow, /save-cache: "true"/);
  assert.match(workflow, /languages: swift\n\s+build-mode: manual/);
});

test("Dependabot groups CodeQL action components", () => {
  assert.match(
    workflows.dependabot,
    /groups:\n\s+codeql-action:\n\s+patterns:\n\s+- "github\/codeql-action\/\*"/,
  );
});

test("PR hygiene consolidates the external checklist", () => {
  const workflow = workflows.template;
  assert.match(workflow, /if: github\.event\.pull_request\.user\.login != 'dependabot\[bot\]'/);
  assert.match(workflow, /MAINTAINER_LOGINS_JSON/);
  assert.match(workflow, /<!-- awesomux-external-pr-checklist -->/);
  assert.match(workflow, /--method PATCH/);
  assert.match(workflow, /--method POST/);
});

test("PR body workflow runs only the trusted base validator", () => {
  const workflow = workflows.template;
  assert.match(workflow, /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/);
  assert.doesNotMatch(workflow, /labeled|unlabeled/);
  assert.match(workflow, /node \.github\/scripts\/validate-pr-body\.mjs/);
  assert.match(workflow, /pull-requests: write/);
  assert.match(workflow, /<!-- awesomux-pr-template-validation -->/);
  assert.match(workflow, /steps\.validator\.outputs\.valid != 'true'/);
});

test("public seed keeps the linked public review guide", () => {
  assert.match(read("README.md"), /\(docs\/code-review\.md\)/);
  assert.ok(existsSync(join(repoRoot, "docs/code-review.md")));

  const seedScript = join(repoRoot, "script/prepare_public_seed.sh");
  if (existsSync(seedScript)) {
    const seed = read("script/prepare_public_seed.sh");
    assert.doesNotMatch(seed, /^\s+docs\/agents\s*$/m);
    assert.doesNotMatch(seed, /docs\/agents\/code-review\.md/);
    assert.match(seed, /docs\/agents\/issue-tracker\.md/);
  }
});
