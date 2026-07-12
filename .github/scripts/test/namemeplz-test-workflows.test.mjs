#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repository = join(here, "../../..");
const planner = readFileSync(
  join(repository, ".github/workflows/namemeplz-runny-dispatch.yml"),
  "utf8",
);
const result = readFileSync(
  join(repository, ".github/workflows/namemeplz-test-result.yml"),
  "utf8",
);

test("automatic planning is maintainer-authored, same-repository, and exact-head", () => {
  assert.match(planner, /types: \[opened, reopened, synchronize, ready_for_review, labeled\]/);
  assert.match(planner, /pull_request\.user\.login/);
  assert.match(planner, /\["serabi", "edequalsawesome"\]/);
  assert.match(planner, /head\.repo\.full_name == github\.repository/);
  assert.match(planner, /pull_request\.head\.sha/);
});

test("CodeRunner defaults closed until the repository is explicitly enabled", () => {
  assert.match(planner, /vars\.CODERUNNER_ENABLED == 'true'/);
  assert.doesNotMatch(planner, /CODERUNNER_ENABLED\s*\|\|/);
});

test("planner checks out only its immutable trusted workflow revision", () => {
  assert.match(planner, /ref: \$\{\{ github\.workflow_sha \}\}/);
  assert.match(planner, /persist-credentials: false/);
  assert.doesNotMatch(planner, /ref: \$\{\{ github\.event\.pull_request\.head/);
  assert.doesNotMatch(planner, /git checkout|git switch/);
});

test("source planner can publish status but dispatcher app remains Actions-only", () => {
  assert.match(planner, /issues: write/);
  assert.match(planner, /pull-requests: write/);
  assert.match(planner, /statuses: write/);
  assert.match(planner, /permission-actions: write/);
  assert.doesNotMatch(planner, /permission-issues: write|permission-statuses: write/);
});

test("result callback accepts only the dedicated reporter app and current SHA", () => {
  assert.match(result, /issues: write/);
  assert.match(result, /pull-requests: write/);
  assert.match(result, /statuses: write/);
  assert.match(result, /coderunner-reporter\[bot\]/);
  assert.match(result, /\.head\.sha == \$sha/);
  assert.match(result, /CodeRunner/);
  assert.match(result, /\$\{#RESULTS\}.*4096/s);
  assert.match(result, /\["guards", "agent-hooks"\]/);
  assert.match(result, /\.\/script\/preflight\.sh/);
  assert.match(result, /CodeRunner does not attest to their result/);
});

test("CodeRunner has one rerun label and no modifier-label menu", () => {
  assert.match(planner, /github\.event\.label\.name == 'CodeRunner'/);
  assert.doesNotMatch(planner, /CodeRunner: (?:amx|ghostty|full)/);
});

test("neither workflow requests changes, enables auto-merge, or merges", () => {
  for (const workflow of [planner, result]) {
    assert.doesNotMatch(workflow, /gh pr review|REQUEST_CHANGES|gh pr merge/);
    assert.doesNotMatch(workflow, /enablePullRequestAutoMerge|enable-auto-merge/);
  }
});
