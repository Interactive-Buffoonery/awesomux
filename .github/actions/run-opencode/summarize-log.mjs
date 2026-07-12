#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function summarizeLog(logText) {
  let inputTokens = 0;
  let outputTokens = 0;
  let totalTokens = 0;
  let truncated = false;
  for (const line of logText.split("\n")) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    if (event?.type === "step_finish") {
      inputTokens += Number(event.part?.tokens?.input || 0);
      outputTokens += Number(event.part?.tokens?.output || 0);
      totalTokens += Number(event.part?.tokens?.total || 0);
    }
    if (event?.part?.state?.output?.truncated === true) truncated = true;
    if (event?.part?.state?.truncated === true) truncated = true;
    if (event?.part?.truncated === true) truncated = true;
  }

  return { inputTokens, outputTokens, totalTokens, truncated };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const inputPath = process.argv[2];
  if (!inputPath) process.exit(2);
  const summary = summarizeLog(readFileSync(inputPath, "utf8"));
  process.stdout.write(
    `${summary.inputTokens}\t${summary.outputTokens}\t${summary.totalTokens}\t${summary.truncated ? "yes" : "no"}\n`,
  );
}
