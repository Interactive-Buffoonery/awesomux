import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { summarizeLog } from "../summarize-log.mjs";

describe("summarizeLog", () => {
  test("accumulates input, output, and total tokens across steps", () => {
    const log = [
      JSON.stringify({ type: "step_finish", part: { tokens: { input: 10, output: 3, total: 13 } } }),
      "not-json",
      JSON.stringify({ type: "step_finish", part: { tokens: { input: 20, output: 5, total: 25 } } }),
    ].join("\n");

    assert.deepEqual(summarizeLog(log), {
      inputTokens: 30,
      outputTokens: 8,
      totalTokens: 38,
      truncated: false,
    });
  });

  test("recognizes supported OpenCode truncation event shapes", () => {
    for (const part of [
      { truncated: true },
      { state: { truncated: true } },
      { state: { output: { truncated: true } } },
    ]) {
      assert.equal(
        summarizeLog(JSON.stringify({ type: "tool_use", part })).truncated,
        true,
      );
    }
  });
});
