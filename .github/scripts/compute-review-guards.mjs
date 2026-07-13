#!/usr/bin/env node

// Computes review guard decisions for the opencode-review workflow.
// Determines whether to skip the automated review based on:
//   1. Docs-only changes — every changed file is documentation/markdown.
//   2. Large diff — total changed lines exceed a threshold.
//
// Writes to GITHUB_OUTPUT:
//   skip=<true|false>
//   skip_body=<full comment body for post-skip-comment.mjs>
//
// Env vars:
//   CHANGED_FILES   — newline-separated list of changed file paths
//   BASE_REF        — base ref for diff computation (default: main)
//   DIFF_THRESHOLD  — max diff lines before skip (default: 2000)

import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const files = (process.env.CHANGED_FILES || "").split("\n").filter(Boolean);
const baseRef = process.env.BASE_REF || "main";
const baseRange = process.env.BASE_RANGE || `origin/${baseRef}...HEAD`;
const threshold = parseInt(process.env.DIFF_THRESHOLD || "2000", 10);
const githubOutput = process.env.GITHUB_OUTPUT || "";

// --- Docs-only check ---

const docsExtensions = [".md", ".txt", ".rst"];
const docsPrefixes = ["docs/"];
const docsRootFiles = [
  "LICENSE",
  "NOTICE",
  "CONTRIBUTING.md",
  "README.md",
  "CHANGELOG.md",
  "AUTHORS",
];

function isDocsFile(file) {
  if (docsExtensions.some((ext) => file.endsWith(ext))) return true;
  if (docsPrefixes.some((p) => file.startsWith(p))) return true;
  if (docsRootFiles.includes(file)) return true;
  return false;
}

const allDocs = files.length > 0 && files.every(isDocsFile);

// --- Diff size check ---

export function countChangedLines(range, runGit = execFileSync) {
  let diffLines = 0;
  const numstat = runGit("git", ["diff", "--numstat", range, "--"], {
    encoding: "utf-8",
  }).trim();
  for (const line of numstat.split("\n")) {
    if (!line) continue;
    const [additions, deletions] = line.split("\t");
    diffLines += parseInt(additions, 10) || 0;
    diffLines += parseInt(deletions, 10) || 0;
  }
  return diffLines;
}

let diffLines = 0;
try {
  diffLines = countChangedLines(baseRange);
} catch {
  // If git diff fails, don't skip — let the review proceed.
}

// --- Decision ---

let skip = false;
let skipTitle = "";
let skipBody = "";

if (allDocs) {
  skip = true;
  skipTitle = "Skipped: docs-only changes";
  const fileList = files.map((f) => `- \`${f}\``).join("\n");
  skipBody = `## OpenCode review skipped\n\nAll changed files in this PR are documentation or markdown. No code review needed.\n\nChanged files (${files.length}):\n${fileList}`;
} else if (diffLines > threshold) {
  skip = true;
  skipTitle = `Skipped: large diff (${diffLines} lines)`;
  skipBody = `## OpenCode automatic review skipped\n\nThis pull request changes ${diffLines} lines, exceeding the ${threshold}-line automatic-review limit. Automatic review was skipped successfully. Comment with exactly \`/codereview\` to trigger OpenCode review manually.`;
}

if (githubOutput) {
  const lines = [`skip=${skip}`, `skip_body<<BODY_EOF`, skipBody, `BODY_EOF`];
  appendFileSync(githubOutput, lines.join("\n") + "\n");
}

if (skip) {
  console.log(`Skip: ${skipTitle}`);
} else {
  console.log(
    `Proceed: ${diffLines} diff lines, ${files.length} files (not all docs)`,
  );
}
