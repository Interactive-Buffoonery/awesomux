import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const readWorkflow = () =>
  readFileSync(join(repoRoot, ".github/workflows/homebrew-cask.yml"), "utf8");

test("only stable published releases can update the Homebrew cask", () => {
  const workflow = readWorkflow();

  assert.match(workflow, /release:\n\s+types: \[published\]/);
  assert.doesNotMatch(workflow, /^\s{2}(?:push|pull_request|workflow_dispatch):/m);
  assert.match(workflow, /if: github\.event\.release\.prerelease == false/);
});

test("published release assets produce a verified tap pull request", () => {
  const workflow = readWorkflow();

  assert.match(workflow, /permissions:\n\s+contents: read/);
  assert.match(workflow, /environment: release/);
  assert.match(workflow, /HOMEBREW_TAP_TOKEN: \$\{\{ secrets\.HOMEBREW_TAP_TOKEN \}\}/);
  assert.match(workflow, /gh release download "\$RELEASE_TAG"/);
  assert.match(workflow, /shasum -a 256 -c/);
  assert.match(workflow, /\.\/script\/update_homebrew_cask\.sh/);
  assert.match(workflow, /gh pr create/);
  assert.doesNotMatch(workflow, /git push[^\n]*(?:origin\s+)?main/);
});
