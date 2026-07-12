#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function extractReview(logText) {
  let review = "";

  for (const line of logText.split("\n")) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    const text = event?.type === "text" ? event.part?.text : null;
    if (typeof text === "string" && text.trimStart().startsWith("## Code Review")) {
      review = text.trim();
    }
  }

  return normalizeReview(review);
}

export function normalizeReview(review) {
  const trimmed = review.trim();
  if (!trimmed) return "";

  const noFindings = /^## Code Review\s+No blocking or should-fix findings\./i;
  const severityFinding = /\[(?:blocking|non-blocking|nit)\]/i;
  if (noFindings.test(trimmed) && !severityFinding.test(trimmed)) {
    return trimmed === "## Code Review\n\nNo blocking or should-fix findings."
      ? trimmed
      : "";
  }

  return trimmed;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const [, , inputPath, outputPath] = process.argv;
  if (!inputPath || !outputPath) {
    console.error("usage: extract-opencode-review.mjs <input-log> <output-markdown>");
    process.exit(2);
  }

  const review = extractReview(readFileSync(inputPath, "utf8"));
  if (!review) process.exit(1);
  writeFileSync(outputPath, `${review}\n`);
}
