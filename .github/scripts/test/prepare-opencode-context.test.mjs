#!/usr/bin/env node

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "../prepare-opencode-context.mjs");

function runHelper(source, maxBytes) {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "opencode-context-test-"));
  const input = join(fixtureRoot, "pull-request.json");
  const output = join(fixtureRoot, "context.txt");
  writeFileSync(input, JSON.stringify(source));
  const result = spawnSync(
    process.execPath,
    [helper, input, output, String(maxBytes)],
    { encoding: "utf8" },
  );
  return { fixtureRoot, output, result };
}

test("writes title and body from a pull_request event", () => {
  const fixture = runHelper(
    { pull_request: { title: "Fix review", body: "Bound the input." } },
    65536,
  );
  try {
    assert.equal(fixture.result.status, 0, fixture.result.stderr);
    assert.equal(
      readFileSync(fixture.output, "utf8"),
      "PR title:\nFix review\n\nPR body:\nBound the input.\n",
    );
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});

test("truncates Unicode metadata without exceeding the byte limit", () => {
  const fixture = runHelper(
    { title: "Unicode", body: `before-${"\u{1D11E}".repeat(100)}-after` },
    128,
  );
  try {
    assert.equal(fixture.result.status, 0, fixture.result.stderr);
    const output = readFileSync(fixture.output);
    const decoded = output.toString("utf8");
    assert.ok(output.length <= 128);
    assert.doesNotMatch(decoded, /�/);
    assert.match(
      decoded,
      /\[PR metadata truncated by the trusted runner\.\]\n$/,
    );
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});

test("rejects a limit too small for the truncation marker", () => {
  const fixture = runHelper({ title: "Tiny", body: "body" }, 1);
  try {
    assert.notEqual(fixture.result.status, 0);
    assert.match(fixture.result.stderr, /usage: prepare-opencode-context/);
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});
