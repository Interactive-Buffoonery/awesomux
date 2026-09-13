#!/usr/bin/env node

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const scriptPath =
  process.env.POST_INLINE_REVIEW_SCRIPT || join(here, "../post-inline-review.mjs");

function git(repoRoot, ...args) {
  return execFileSync("git", args, {
    cwd: repoRoot,
    encoding: "utf-8",
  }).trim();
}

function createFixture() {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "inline-review-range-"));
  const repoRoot = join(fixtureRoot, "repo");
  const logPath = join(fixtureRoot, "opencode.log");
  const fetchCapture = join(fixtureRoot, "fetch.jsonl");
  const fetchMock = join(fixtureRoot, "mock-fetch.mjs");

  git(fixtureRoot, "init", "--quiet", repoRoot);
  git(repoRoot, "config", "user.name", "Review Test");
  git(repoRoot, "config", "user.email", "review-test@example.com");
  writeFileSync(join(repoRoot, "stable.md"), "stable\n");
  git(repoRoot, "add", "stable.md");
  git(repoRoot, "commit", "--quiet", "-m", "initial");
  const baseSHA = git(repoRoot, "rev-parse", "HEAD");

  writeFileSync(join(repoRoot, "changed.md"), "changed\n");
  git(repoRoot, "add", "changed.md");
  git(repoRoot, "commit", "--quiet", "-m", "change");
  const headSHA = git(repoRoot, "rev-parse", "HEAD");

  writeFileSync(
    logPath,
    [
      "[10:00:00.000] INFO (#1): llm runtime selected {",
      "}",
      "## Code Review",
      "",
      "### Should fix",
      "- `changed.md:1` — Check the changed line.",
      "Checking if branch is dirty...",
    ].join("\n"),
  );
  writeFileSync(
    fetchMock,
    `import { appendFileSync } from "node:fs";

globalThis.fetch = async (url, options = {}) => {
  const method = options.method || "GET";
  appendFileSync(
    process.env.FETCH_CAPTURE,
    JSON.stringify({ url: String(url), method, body: options.body || null }) + "\\n",
  );
  if (method === "POST") {
    return new Response(
      JSON.stringify({ id: 1, html_url: "https://example.test/review/1" }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }
  return new Response("[]", {
    status: 200,
    headers: { "content-type": "application/json" },
  });
};
`,
  );

  return {
    fixtureRoot,
    repoRoot,
    logPath,
    fetchCapture,
    fetchMock,
    baseSHA,
    headSHA,
  };
}

function runPublisher(fixture, rangeEnvironment) {
  return spawnSync(
    process.execPath,
    ["--import", pathToFileURL(fixture.fetchMock).href, scriptPath],
    {
      encoding: "utf-8",
      env: {
        ...process.env,
        OPENCODE_LOG: fixture.logPath,
        GH_TOKEN: "test-token",
        GITHUB_REPOSITORY: "example/awesomux",
        PR_NUMBER: "1",
        REPO_ROOT: fixture.repoRoot,
        FETCH_CAPTURE: fixture.fetchCapture,
        ...rangeEnvironment,
      },
    },
  );
}

function postedReview(fixture) {
  const requests = readFileSync(fixture.fetchCapture, "utf-8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  const request = requests.find((entry) => entry.method === "POST");
  assert.ok(request, "expected the mocked review POST");
  return JSON.parse(request.body);
}

test("uses BASE_RANGE for inline mapping and reviewed files", () => {
  const fixture = createFixture();
  try {
    const baseRange = `${fixture.baseSHA}...${fixture.headSHA}`;
    const result = runPublisher(fixture, {
      BASE_RANGE: baseRange,
      BASE_REF: "missing-fallback-ref",
    });

    assert.equal(result.status, 0, result.stderr);
    const review = postedReview(fixture);
    assert.deepEqual(review.comments, [
      {
        path: "changed.md",
        line: 1,
        side: "RIGHT",
        body: "**[non-blocking]** — Check the changed line.",
      },
    ]);
    assert.match(review.body, /Files reviewed \(1\)/);
    assert.match(review.body, /- `changed\.md`/);
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});

test("empty range settings retain the main fallback", () => {
  const fixture = createFixture();
  try {
    git(
      fixture.repoRoot,
      "update-ref",
      "refs/remotes/origin/main",
      fixture.baseSHA,
    );
    const result = runPublisher(fixture, { BASE_RANGE: "", BASE_REF: "" });

    assert.equal(result.status, 0, result.stderr);
    const review = postedReview(fixture);
    assert.equal(review.comments[0]?.path, "changed.md");
    assert.match(review.body, /- `changed\.md`/);
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});

test("a named base ref remains available as the fallback", () => {
  const fixture = createFixture();
  try {
    git(
      fixture.repoRoot,
      "update-ref",
      "refs/remotes/origin/release",
      fixture.baseSHA,
    );
    const result = runPublisher(fixture, {
      BASE_RANGE: "",
      BASE_REF: "release",
    });

    assert.equal(result.status, 0, result.stderr);
    const review = postedReview(fixture);
    assert.equal(review.comments[0]?.path, "changed.md");
    assert.match(review.body, /- `changed\.md`/);
  } finally {
    rmSync(fixture.fixtureRoot, { recursive: true, force: true });
  }
});
