import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { extractReview, normalizeReview } from "../extract-opencode-review.mjs";

describe("extractReview", () => {
  test("returns the last complete code review text event", () => {
    const log = [
      JSON.stringify({ type: "text", part: { text: "I will inspect the diff." } }),
      JSON.stringify({ type: "tool_use", part: { tool: "bash" } }),
      JSON.stringify({
        type: "text",
        part: { text: "## Code Review\n\nNo blocking or should-fix findings." },
      }),
    ].join("\n");

    assert.equal(
      extractReview(log),
      "## Code Review\n\nNo blocking or should-fix findings.",
    );
  });

  test("fails closed for narration-only output", () => {
    const log = JSON.stringify({
      type: "text",
      part: { text: "I inspected the diff and found no issues." },
    });

    assert.equal(extractReview(log), "");
  });

  test("ignores malformed and non-text events", () => {
    const log = [
      "not json",
      JSON.stringify({ type: "error", error: "provider failed" }),
      JSON.stringify({ type: "text", part: {} }),
    ].join("\n");

    assert.equal(extractReview(log), "");
  });
});

describe("normalizeReview", () => {
  test("rejects verbose no-findings output instead of hiding extra text", () => {
    assert.equal(
      normalizeReview(
        "## Code Review\n\nNo blocking or should-fix findings.\n\nThe implementation is excellent and well-tested.",
      ),
      "",
    );
  });

  test("rejects an unlabeled concern after a no-findings sentence", () => {
    assert.equal(
      normalizeReview(
        "## Code Review\n\nNo blocking or should-fix findings.\n\nHowever, this exposes a credential.",
      ),
      "",
    );
  });

  test("preserves reviews containing severity-labelled findings", () => {
    const review =
      "## Code Review\n\nNo blocking or should-fix findings in the main path.\n\n[nit] Rename the fixture.";
    assert.equal(normalizeReview(review), review);
  });
});
