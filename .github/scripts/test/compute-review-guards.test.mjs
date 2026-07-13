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

test("counts the immutable PR range and emits a manual-trigger notice", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "review-guards-"));
  try {
    const binDirectory = join(fixtureRoot, "bin");
    const gitPath = join(binDirectory, "git");
    const outputPath = join(fixtureRoot, "github-output");
    const argumentsPath = join(fixtureRoot, "git-arguments");

    mkdirSync(binDirectory);
    writeFileSync(
      gitPath,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$@" > "$GIT_ARGUMENTS_CAPTURE"\nprintf '1200\\t900\\tSources/Large.swift\\n'\n`,
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
      `diff\n--numstat\n${baseRange}\n--\n`,
    );

    const output = readFileSync(outputPath, "utf-8");
    assert.match(output, /^skip=true$/m);
    assert.match(output, /This pull request changes 2100 lines/);
    assert.match(output, /Automatic review was skipped successfully\./);
    assert.match(output, /`\/codereview` to trigger OpenCode review manually/);
    assert.doesNotMatch(output, /codebase/i);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
