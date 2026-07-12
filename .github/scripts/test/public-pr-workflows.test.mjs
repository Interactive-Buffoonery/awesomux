import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const read = (path) => readFileSync(join(repoRoot, path), "utf8");

const workflows = {
  size: read(".github/workflows/pr-size.yml"),
  template: read(".github/workflows/pr-template.yml"),
};

function assertMetadataOnly(name, workflow) {
  assert.match(workflow, /pull_request_target:/, `${name} must run trusted base workflow code`);
  assert.match(
    workflow,
    /runs-on: blacksmith-2vcpu-ubuntu-2404/,
    `${name} must use the smallest Blacksmith runner`,
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

test("all contributor workflows preserve the metadata-only trust boundary", () => {
  for (const [name, workflow] of Object.entries(workflows)) {
    assertMetadataOnly(name, workflow);
  }
});

test("PR sizing uses a verified passive ref and effective line rules", () => {
  const workflow = workflows.size;
  assert.match(workflow, /runs-on: blacksmith-2vcpu-ubuntu-2404/);
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

test("PR hygiene consolidates the external checklist", () => {
  const workflow = workflows.template;
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
