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
};
const ensureRepositoryLabel = join(repoRoot, ".github/scripts/ensure-repository-label.sh");

function runEnsureRepositoryLabel({ lookupError, lookupResponse, lookupWarning = "" }) {
  const fixture = mkdtempSync(join(tmpdir(), "awesomux-label-test-"));
  const calls = join(fixture, "calls");
  const mockGh = join(fixture, "gh");
  const script = `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$GH_CALLS"
if [[ "$1" == "api" && "\${2:-}" != "--method" ]]; then
    if [[ -n "\${GH_LOOKUP_ERROR:-}" ]]; then
        printf '%s\\n' "$GH_LOOKUP_ERROR" >&2
        exit 1
    fi
    printf '%s\\n' "$GH_LOOKUP_RESPONSE"
    if [[ -n "\${GH_LOOKUP_WARNING:-}" ]]; then
        printf '%s\\n' "$GH_LOOKUP_WARNING" >&2
    fi
fi
`;

  writeFileSync(mockGh, script);
  chmodSync(mockGh, 0o755);

  const result = spawnSync(
    "bash",
    [ensureRepositoryLabel, "Interactive-Buffoonery/awesomux", "size:S", "5ebd3e", "10-29 effective changed lines."],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        GH_CALLS: calls,
        GH_LOOKUP_ERROR: lookupError ?? "",
        GH_LOOKUP_RESPONSE: lookupResponse ?? "",
        GH_LOOKUP_WARNING: lookupWarning,
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

test("a missing repository label is created for either gh 404 format", () => {
  for (const lookupError of [
    "gh: Not Found (HTTP 404)",
    "gh: HTTP 404: Not Found (https://api.github.com/example)",
  ]) {
    const result = runEnsureRepositoryLabel({ lookupError });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.recordedCalls, /api --method POST repos\/Interactive-Buffoonery\/awesomux\/labels/);
  }
});

test("a temporary label lookup failure is surfaced without a write", () => {
  const result = runEnsureRepositoryLabel({
    lookupError: "gh: No server is currently available (HTTP 503)",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /HTTP 503/);
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

test("interpreted CodeQL stays automatic without waiting for Swift", () => {
  const workflow = workflows.codeql;
  assertMatchingCodeQLActionPins("interpreted CodeQL", workflow);
  assert.match(workflow, /push:\n\s+branches: \[main\]/);
  assert.match(workflow, /pull_request:\n\s+branches: \[main\]/);
  assert.match(workflow, /matrix:\n\s+language: \[actions, python\]/);
  assert.doesNotMatch(workflow, /schedule:|workflow_dispatch:|Analyze \(swift\)|needs: \[[^\]]*swift/);
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
