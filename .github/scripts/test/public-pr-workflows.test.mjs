import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const workflows = Object.fromEntries(["size", "template"].map((name) => [name,
  readFileSync(new URL(`../../workflows/pr-${name}.yml`, import.meta.url), "utf8")
]));

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

test("all contributor workflows preserve the metadata-only trust boundary", () => {
  for (const [name, workflow] of Object.entries({
    size: workflows.size,
    template: workflows.template,
  })) {
    assertMetadataOnly(name, workflow);
  }
});
