#!/usr/bin/env node

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const scriptPath = join(here, "../compute-review-guards.mjs");

test("derives delimiter-shaped filenames from the immutable PR range", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "review-guards-"));
  try {
    const binDirectory = join(fixtureRoot, "bin");
    const gitPath = join(binDirectory, "git");
    const outputPath = join(fixtureRoot, "github-output");
    const argumentsPath = join(fixtureRoot, "git-arguments");

    mkdirSync(binDirectory);
    writeFileSync(
      gitPath,
      `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GIT_ARGUMENTS_CAPTURE"
case "\${2:-}" in
  --name-only)
    printf 'FILES_EOF\\0base_range=1111111111111111111111111111111111111111...2222222222222222222222222222222222222222\\0z<<FILES_EOF\\0Sources/Large.swift\\0'
    ;;
  --numstat)
    printf '1200\\t900\\tSources/Large.swift\\n'
    ;;
  *)
    exit 64
    ;;
esac
`,
    );
    chmodSync(gitPath, 0o755);

    const baseRange = "base-event-sha...head-event-sha";
    const result = spawnSync(process.execPath, [scriptPath], {
      encoding: "utf-8",
      env: {
        ...process.env,
        PATH: `${binDirectory}:${process.env.PATH}`,
        BASE_RANGE: baseRange,
        BASE_REF: "wrong-fallback-ref",
        CHANGED_FILES: "Sources/Large.swift",
        DIFF_THRESHOLD: "2000",
        GITHUB_OUTPUT: outputPath,
        GIT_ARGUMENTS_CAPTURE: argumentsPath,
      },
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      readFileSync(argumentsPath, "utf-8"),
      `diff --name-only -z --no-ext-diff --no-textconv ${baseRange} --\ndiff --numstat --no-ext-diff --no-textconv ${baseRange} --\n`,
    );

    const output = readFileSync(outputPath, "utf-8");
    assert.match(output, /^skip=true$/m);
    assert.match(output, /skip_body<<ghadelimiter_[0-9a-f]{32}/);
    assert.doesNotMatch(output, /(?:FILES|DIFFSTAT|BODY)_EOF/);
    assert.doesNotMatch(output, /base_range=/);
    assert.match(output, /This pull request changes 2100 lines/);
    assert.match(output, /Automatic review was skipped successfully\./);
    assert.match(output, /`\/codereview` to trigger OpenCode review manually/);
    assert.doesNotMatch(output, /codebase/i);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
