#!/usr/bin/env node

// Unit tests for the pure functions in post-inline-review.mjs.
// Run: node .github/scripts/test/parse-review-findings.test.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildReviewBody,
  buildReviewedFilesSection,
  deleteTemporaryReviewComment,
  extractPostedRegion,
  extractReviewBody,
  findTemporaryReviewComment,
  parseFindings,
  parseDiffHunks,
  isCommentable,
  upsertReviewedFilesSection,
} from "../post-inline-review.mjs";

// ── extractPostedRegion ──

describe("extractPostedRegion", () => {
  test("extracts text between last 'llm runtime selected' and 'Checking if branch is dirty...'", () => {
    const log = [
      "[22:16:10.101] INFO (#2959): loop {",
      '  "session.id": "ses_example",',
      "  step: 0,",
      "}",
      "[22:16:11.212] INFO (#2960): llm runtime selected {",
      '  "llm.runtime": "ai-sdk",',
      '  "llm.provider": "synthetic",',
      '  "llm.model": "hf:zai-org/GLM-5.2",',
      "}",
      "## Code Review",
      "",
      "**Blockers:** 1 | **Should fix:** 0 | **Nits:** 0",
      "",
      "### Blockers",
      "- `Sources/Foo.swift:42` — Force unwrap can crash; use optional binding.",
      "Checking if branch is dirty...",
    ].join("\n");

    const region = extractPostedRegion(log);
    // The region includes the JSON log lines before ## Code Review
    // (matching the AWK behavior in guard.sh)
    assert.ok(region.includes("## Code Review"));
    assert.ok(region.includes("### Blockers"));
    assert.ok(!region.includes("Checking if branch is dirty"));
    assert.ok(!region.includes("llm runtime selected"));
  });

  test("uses the LAST region when multiple exist", () => {
    const log = [
      "[10:00:00.000] INFO (#1): llm runtime selected {",
      "}",
      "## Code Review",
      "first review (should be discarded)",
      "Checking if branch is dirty...",
      "",
      "[10:01:00.000] INFO (#2): llm runtime selected {",
      "}",
      "## Code Review",
      "second review (should be kept)",
      "Checking if branch is dirty...",
    ].join("\n");

    const region = extractPostedRegion(log);
    assert.ok(region.includes("second review"));
    assert.ok(!region.includes("first review"));
  });

  test("returns empty string when no markers found", () => {
    assert.equal(extractPostedRegion("no markers here"), "");
  });
});

describe("extractReviewBody", () => {
  test("strips terminal escapes and runtime log tail from a posted review", () => {
    const log = readFileSync(
      new URL(
        "./fixtures/review-with-findings.log",
        import.meta.url,
      ),
      "utf-8",
    );
    const review = extractReviewBody(extractPostedRegion(log));

    assert.ok(review.startsWith("## Code Review"));
    assert.ok(review.includes("Force unwrap on optional value"));
    assert.ok(!review.includes("\x1B"));
    assert.ok(!review.includes("^["));
    assert.ok(!review.includes("tracking {"));
    assert.ok(!review.includes("session.id"));
    assert.ok(!review.includes("Checking if branch is dirty"));
  });

  test("returns empty string when the posted region has no review header", () => {
    assert.equal(extractReviewBody("No review here"), "");
  });
});

// ── parseFindings ──

describe("parseFindings", () => {
  test("parses section-based findings with correct severity", () => {
    const review = [
      "## Code Review",
      "",
      "**Blockers:** 2 | **Should fix:** 1 | **Nits:** 1",
      "",
      "### Blockers",
      "- `Sources/Foo.swift:42` — Force unwrap can crash; use optional binding.",
      "- `Sources/Bar.swift:100` — Missing MainActor isolation; add @MainActor.",
      "",
      "### Should fix",
      "- `Sources/Baz.swift:15` — Inconsistent error handling; use do-catch.",
      "",
      "### Nits",
      "- `Sources/Qux.swift:8` — Variable name could be more descriptive.",
    ].join("\n");

    const findings = parseFindings(review);
    assert.equal(findings.length, 4);
    assert.equal(findings[0].file, "Sources/Foo.swift");
    assert.equal(findings[0].line, 42);
    assert.equal(findings[0].severity, "blocking");
    assert.equal(findings[1].file, "Sources/Bar.swift");
    assert.equal(findings[1].severity, "blocking");
    assert.equal(findings[2].severity, "non-blocking");
    assert.equal(findings[3].severity, "nit");
  });

  test("parses label-based findings with inline severity", () => {
    const review = [
      "## Code Review",
      "",
      "- [blocking] `Sources/Foo.swift:42` — Force unwrap can crash; use optional binding.",
      "- [nit] `Sources/Bar.swift:8` — Variable name could be more descriptive.",
    ].join("\n");

    const findings = parseFindings(review);
    assert.equal(findings.length, 2);
    assert.equal(findings[0].severity, "blocking");
    assert.equal(findings[1].severity, "nit");
  });

  test("defaults to non-blocking when no severity context", () => {
    const review = "- `Sources/Foo.swift:42` — Some issue; fix it.";
    const findings = parseFindings(review);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].severity, "non-blocking");
  });

  test("returns empty array for no-findings review", () => {
    const review = "## Code Review\n\nNo blocking or should-fix findings.";
    assert.deepEqual(parseFindings(review), []);
  });

  test("handles regular dash separator (not just em-dash)", () => {
    const review = "- `Sources/Foo.swift:42` - Some issue; fix it.";
    const findings = parseFindings(review);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].text, "Some issue; fix it.");
  });

  test("captures the full finding text including semicolons", () => {
    const review =
      "- `Sources/Foo.swift:42` — Force unwrap on optional; use guard let instead.";
    const findings = parseFindings(review);
    assert.equal(
      findings[0].text,
      "Force unwrap on optional; use guard let instead.",
    );
  });
});

// ── parseDiffHunks ──

describe("parseDiffHunks", () => {
  test("extracts file paths and hunk line ranges", () => {
    const diff = [
      "diff --git a/Sources/Foo.swift b/Sources/Foo.swift",
      "index abc..def 100644",
      "--- a/Sources/Foo.swift",
      "+++ b/Sources/Foo.swift",
      "@@ -40,7 +42,12 @@",
      "   context line",
      "-  removed line",
      "+  added line 1",
      "+  added line 2",
      "   context line",
      "@@ -60,3 +65,5 @@",
      "   context line",
      "+  added line 3",
      "   context line",
      "diff --git a/Sources/Bar.swift b/Sources/Bar.swift",
      "--- a/Sources/Bar.swift",
      "+++ b/Sources/Bar.swift",
      "@@ -10,3 +10,3 @@",
      "   context",
      "-  old",
      "+  new",
    ].join("\n");

    const fileMap = parseDiffHunks(diff);
    assert.ok(fileMap.has("Sources/Foo.swift"));
    assert.ok(fileMap.has("Sources/Bar.swift"));

    const fooRanges = fileMap.get("Sources/Foo.swift");
    assert.equal(fooRanges.length, 2);
    assert.deepEqual(fooRanges[0], [42, 53]); // +42,12 → 42..53
    assert.deepEqual(fooRanges[1], [65, 69]); // +65,5 → 65..69

    const barRanges = fileMap.get("Sources/Bar.swift");
    assert.deepEqual(barRanges[0], [10, 12]); // +10,3 → 10..12
  });

  test("handles single-line hunk count (no comma)", () => {
    const diff = [
      "diff --git a/Foo.swift b/Foo.swift",
      "--- a/Foo.swift",
      "+++ b/Foo.swift",
      "@@ -1 +1 @@",
      "-old",
      "+new",
    ].join("\n");

    const fileMap = parseDiffHunks(diff);
    assert.deepEqual(fileMap.get("Foo.swift"), [[1, 1]]);
  });

  test("returns empty map for empty diff", () => {
    assert.equal(parseDiffHunks("").size, 0);
  });
});

// ── isCommentable ──

describe("isCommentable", () => {
  const fileMap = new Map([
    ["Sources/Foo.swift", [[42, 53], [65, 69]]],
    ["Sources/Bar.swift", [[10, 12]]],
  ]);

  test("returns true for lines within a hunk range", () => {
    assert.ok(isCommentable(fileMap, "Sources/Foo.swift", 42));
    assert.ok(isCommentable(fileMap, "Sources/Foo.swift", 50));
    assert.ok(isCommentable(fileMap, "Sources/Foo.swift", 53));
    assert.ok(isCommentable(fileMap, "Sources/Foo.swift", 67));
  });

  test("returns false for lines outside hunk ranges", () => {
    assert.ok(!isCommentable(fileMap, "Sources/Foo.swift", 41));
    assert.ok(!isCommentable(fileMap, "Sources/Foo.swift", 54));
    assert.ok(!isCommentable(fileMap, "Sources/Foo.swift", 64));
    assert.ok(!isCommentable(fileMap, "Sources/Foo.swift", 70));
  });

  test("returns false for files not in the diff", () => {
    assert.ok(!isCommentable(fileMap, "Sources/Baz.swift", 1));
  });

  test("returns false for empty map", () => {
    assert.ok(!isCommentable(new Map(), "Sources/Foo.swift", 42));
  });
});

// ── review body publishing ──

describe("buildReviewedFilesSection", () => {
  test("renders the reviewed-files details block", () => {
    const section = buildReviewedFilesSection([
      "Sources/Foo.swift",
      "Tests/FooTests.swift",
    ]);

    assert.ok(section.includes("<!-- awesomux-reviewed-files -->"));
    assert.ok(section.includes("<details><summary>Files reviewed (2)</summary>"));
    assert.ok(section.includes("- `Sources/Foo.swift`"));
    assert.ok(section.includes("- `Tests/FooTests.swift`"));
  });
});

describe("buildReviewBody", () => {
  test("embeds the full OpenCode review and reviewed files", () => {
    const body = buildReviewBody({
      reviewBody: [
        "## Code Review",
        "",
        "**Blockers:** 0 | **Should fix:** 1 | **Nits:** 0",
        "",
        "### Should fix",
        "- `Sources/Foo.swift:42` — Use optional binding.",
      ].join("\n"),
      inlineCount: 1,
      findingCount: 1,
      outsideDiff: [],
      reviewedFiles: ["Sources/Foo.swift"],
    });

    assert.ok(body.startsWith("<!-- awesomux-inline-review -->"));
    assert.ok(body.includes("## OpenCode Inline Review"));
    assert.ok(body.includes("Posted 1 inline comment(s) for 1 finding(s)."));
    assert.ok(body.includes("### Code Review"));
    assert.ok(body.includes("**Blockers:** 0 | **Should fix:** 1 | **Nits:** 0"));
    assert.ok(body.includes("<!-- awesomux-reviewed-files -->"));
    assert.ok(!body.includes("_Full review in the comment above._"));
  });

  test("keeps outside-diff findings in the review body", () => {
    const body = buildReviewBody({
      reviewBody: "## Code Review\n\nOne issue is outside the diff.",
      inlineCount: 0,
      findingCount: 1,
      outsideDiff: [
        {
          file: "Sources/Foo.swift",
          line: 100,
          severity: "non-blocking",
          text: "Outside the current hunk.",
        },
      ],
      reviewedFiles: [],
    });

    assert.ok(body.includes("Posted 0 inline comment(s) for 1 finding(s)."));
    assert.ok(body.includes("### 1 finding(s) on lines outside the diff"));
    assert.ok(
      body.includes(
        "- `Sources/Foo.swift:100` — **[non-blocking]** Outside the current hunk.",
      ),
    );
  });

  test("supports no-finding reviews", () => {
    const body = buildReviewBody({
      reviewBody: "## Code Review\n\nNo material findings.",
      inlineCount: 0,
      findingCount: 0,
      outsideDiff: [],
      reviewedFiles: ["README.md"],
    });

    assert.ok(body.includes("Posted 0 inline comment(s) for 0 finding(s)."));
    assert.ok(body.includes("No material findings."));
    assert.ok(body.includes("Files reviewed (1)"));
  });
});

describe("upsertReviewedFilesSection", () => {
  test("appends reviewed files to a native OpenCode review comment", () => {
    const body = upsertReviewedFilesSection(
      "## Code Review\n\nNo material findings.",
      ["Sources/Foo.swift", "Tests/FooTests.swift"],
    );

    assert.ok(body.startsWith("## Code Review"));
    assert.ok(body.includes("<!-- awesomux-reviewed-files -->"));
    assert.ok(body.includes("Files reviewed (2)"));
    assert.ok(body.includes("- `Sources/Foo.swift`"));
    assert.ok(body.includes("- `Tests/FooTests.swift`"));
  });

  test("replaces an existing reviewed files section", () => {
    const original = [
      "## Code Review",
      "",
      "No material findings.",
      "",
      buildReviewedFilesSection(["Sources/Old.swift"]),
    ].join("\n");

    const body = upsertReviewedFilesSection(original, [
      "Sources/New.swift",
      "Sources/$&.swift",
    ]);
    const secondPass = upsertReviewedFilesSection(body, [
      "Sources/New.swift",
      "Sources/$&.swift",
    ]);

    assert.ok(body.includes("- `Sources/New.swift`"));
    assert.ok(body.includes("- `Sources/$&.swift`"));
    assert.ok(!body.includes("- `Sources/Old.swift`"));
    assert.equal(
      body.match(/<!-- awesomux-reviewed-files -->/g)?.length,
      1,
    );
    assert.equal(secondPass, body);
  });

  test("leaves the body unchanged when there are no reviewed files", () => {
    const original = "## Code Review\n\nNo material findings.";

    assert.equal(upsertReviewedFilesSection(original, []), original);
  });
});

describe("findTemporaryReviewComment", () => {
  test("selects the newest top-level OpenCode review comment", () => {
    const comment = findTemporaryReviewComment([
      {
        id: 1,
        created_at: "2026-07-07T01:00:00Z",
        user: { login: "github-actions[bot]" },
        body: "## Code Review\n\nOld review",
      },
      {
        id: 2,
        created_at: "2026-07-07T02:00:00Z",
        user: { login: "github-actions[bot]" },
        body: "## Code Review\n\nNew review",
      },
      {
        id: 3,
        created_at: "2026-07-07T03:00:00Z",
        user: { login: "github-actions[bot]" },
        body: "<!-- awesomux-inline-review -->\n## OpenCode Inline Review",
      },
    ]);

    assert.equal(comment.id, 2);
  });

  test("ignores comments from other authors", () => {
    const comment = findTemporaryReviewComment([
      {
        id: 1,
        created_at: "2026-07-07T01:00:00Z",
        user: { login: "serabi" },
        body: "## Code Review\n\nHuman note",
      },
    ]);

    assert.equal(comment, undefined);
  });
});

describe("deleteTemporaryReviewComment", () => {
  test("deletes the selected temporary review comment", async () => {
    const deletedIds = [];
    const deleted = await deleteTemporaryReviewComment(
      [
        {
          id: 42,
          created_at: "2026-07-07T02:00:00Z",
          user: { login: "github-actions[bot]" },
          body: "## Code Review\n\nTemporary review",
        },
      ],
      async (comment) => {
        deletedIds.push(comment.id);
      },
    );

    assert.equal(deleted.id, 42);
    assert.deepEqual(deletedIds, [42]);
  });

  test("does not call delete when no temporary review comment exists", async () => {
    let calls = 0;
    const deleted = await deleteTemporaryReviewComment(
      [
        {
          id: 42,
          created_at: "2026-07-07T02:00:00Z",
          user: { login: "github-actions[bot]" },
          body: "<!-- awesomux-inline-review -->\n## OpenCode Inline Review",
        },
      ],
      async () => {
        calls += 1;
      },
    );

    assert.equal(deleted, null);
    assert.equal(calls, 0);
  });
});
