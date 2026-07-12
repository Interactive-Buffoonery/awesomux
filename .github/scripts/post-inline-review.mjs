#!/usr/bin/env node

// Post inline GitHub PR review comments from an OpenCode review run.
//
// Reads the opencode run log, extracts the posted review region (the same
// AWK logic as guard.sh's extract_posted_region), parses structured findings
// (`file:line — problem; fix`) and maps them to the PR's diff hunks. When
// there are mappable findings, the full review body and reviewed-files list move
// into a GitHub PR Review, then the temporary top-level OpenCode issue comment
// is deleted after the review posts. Clean reviews stay as native OpenCode
// comments and get the reviewed-files list appended in place.
//
// Env vars:
//   OPENCODE_LOG     — path to the opencode run log file
//   GH_TOKEN         — GitHub token with pull-requests:write and issues:write
//   GITHUB_REPOSITORY — owner/repo
//   PR_NUMBER        — pull request number
//   BASE_REF         — base ref for diff computation (default: main)
//   REPO_ROOT        — repo root for git diff (default: cwd)

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

// ── Pure functions (exported for testing) ──

const terminalEscapePattern =
  /(?:\x1B|\^\[)(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g;
const opencodeRuntimeLogLinePattern =
  /^\[[0-9:.]+\]\s+(?:TRACE|DEBUG|INFO|WARN|ERROR)\s+\(#[0-9]+\):\s/;
const opencodePostCommentLinePattern =
  /^(?:Checking if branch is dirty|Creating comment|Removing reaction)\.\.\.$/;
const reviewedFilesMarker = "<!-- awesomux-reviewed-files -->";

/**
 * Extract the posted region from an opencode run log — the text between the
 * last "llm runtime selected" marker and "Checking if branch is dirty...".
 * Mirrors the AWK logic in guard.sh's extract_posted_region.
 */
export function extractPostedRegion(logText) {
  const lines = logText.split("\n");
  let captured = [];
  let capturing = false;

  for (const line of lines) {
    if (/^\[[0-9:.]+\] INFO \(#[0-9]+\): llm runtime selected/.test(line)) {
      capturing = true;
      captured = [];
      continue;
    }
    if (/^Checking if branch is dirty\.\.\./.test(line)) {
      capturing = false;
    }
    if (capturing) {
      captured.push(line);
    }
  }

  return captured.join("\n").trim();
}

/**
 * Extract the markdown review body from a posted region and strip OpenCode's
 * terminal/log tail so it cannot leak into the GitHub PR Review body.
 */
export function extractReviewBody(postedRegion) {
  const reviewStart = postedRegion.indexOf("## Code Review");
  if (reviewStart === -1) return "";

  const reviewLines = [];
  for (const rawLine of postedRegion.slice(reviewStart).split("\n")) {
    const line = rawLine.replace(terminalEscapePattern, "");
    if (
      opencodeRuntimeLogLinePattern.test(line) ||
      opencodePostCommentLinePattern.test(line)
    ) {
      break;
    }
    reviewLines.push(line);
  }

  return reviewLines.join("\n").trim();
}

/**
 * Parse structured findings from a review text block.
 *
 * Supports two formats:
 *   1. Section-based (from the pr-review skill):
 *      ### Blockers
 *      - `file:line` — problem; fix.
 *   2. Label-based (inline severity):
 *      - [blocking] `file:line` — problem; fix.
 *
 * Returns: [{ file, line, severity, text }]
 */
export function parseFindings(reviewText) {
  const findings = [];
  const lines = reviewText.split("\n");
  let currentSeverity = null;

  const findingRegex =
    /^\s*-\s*(?:\[(blocking|non-blocking|nit)\]\s*)?`([^`]+):(\d+)`\s*[—–-]\s*(.+)$/;

  for (const line of lines) {
    if (/^###\s+Blockers/i.test(line)) {
      currentSeverity = "blocking";
      continue;
    }
    if (/^###\s+Should\s*fix/i.test(line)) {
      currentSeverity = "non-blocking";
      continue;
    }
    if (/^###\s+Nits/i.test(line)) {
      currentSeverity = "nit";
      continue;
    }

    const match = line.match(findingRegex);
    if (match) {
      const severity = match[1] || currentSeverity || "non-blocking";
      findings.push({
        file: match[2],
        line: parseInt(match[3], 10),
        severity,
        text: match[4].trim(),
      });
    }
  }

  return findings;
}

/**
 * Parse a unified diff and return a map of file → [[startLine, endLine], ...]
 * for each hunk's range in the new file. Lines within these ranges are
 * commentable on GitHub PR Reviews.
 */
export function parseDiffHunks(diffText) {
  const fileMap = new Map();
  const lines = diffText.split("\n");
  let currentFile = null;

  for (const line of lines) {
    const plusMatch = line.match(/^\+\+\+\s+b\/(.+)$/);
    if (plusMatch) {
      currentFile = plusMatch[1];
      if (!fileMap.has(currentFile)) fileMap.set(currentFile, []);
      continue;
    }

    const hunkMatch = line.match(
      /^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@/,
    );
    if (hunkMatch && currentFile) {
      const start = parseInt(hunkMatch[1], 10);
      const count = hunkMatch[2] ? parseInt(hunkMatch[2], 10) : 1;
      fileMap.get(currentFile).push([start, start + count - 1]);
      continue;
    }
  }

  return fileMap;
}

/**
 * Check whether a file:line falls within any diff hunk range.
 */
export function isCommentable(fileMap, file, line) {
  const ranges = fileMap.get(file);
  if (!ranges) return false;
  return ranges.some(([start, end]) => line >= start && line <= end);
}

export function buildReviewedFilesSection(files) {
  const list = files.map((file) => `- \`${file}\``).join("\n");
  return [
    reviewedFilesMarker,
    "",
    `<details><summary>Files reviewed (${files.length})</summary>`,
    "",
    list,
    "",
    "</details>",
  ].join("\n");
}

export function upsertReviewedFilesSection(body, reviewedFiles) {
  if (reviewedFiles.length === 0) return body;

  const filesSection = buildReviewedFilesSection(reviewedFiles);
  if (!body.includes(reviewedFilesMarker)) {
    return `${body}\n\n${filesSection}`;
  }

  const markerPattern = reviewedFilesMarker.replace(
    /[.*+?^${}()|[\]\\]/g,
    "\\$&",
  );
  return body.replace(new RegExp(`${markerPattern}.*`, "s"), () => filesSection);
}

export function buildReviewBody({
  reviewBody,
  inlineCount,
  findingCount,
  outsideDiff,
  reviewedFiles,
}) {
  const parts = [
    "<!-- awesomux-inline-review -->",
    "## OpenCode Inline Review",
    "",
    `Posted ${inlineCount} inline comment(s) for ${findingCount} finding(s).`,
    "",
    reviewBody.replace(/^## Code Review/m, "### Code Review").trim(),
  ];

  if (outsideDiff.length > 0) {
    parts.push("");
    parts.push(`### ${outsideDiff.length} finding(s) on lines outside the diff`);
    for (const finding of outsideDiff) {
      parts.push(
        `- \`${finding.file}:${finding.line}\` — **[${finding.severity}]** ${finding.text}`,
      );
    }
  }

  if (reviewedFiles.length > 0) {
    parts.push("");
    parts.push(buildReviewedFilesSection(reviewedFiles));
  }

  return parts.join("\n");
}

export function findTemporaryReviewComment(comments) {
  return comments
    .filter(
      (comment) =>
        comment.user?.login === "github-actions[bot]" &&
        /^## Code Review/m.test(comment.body ?? "") &&
        !comment.body?.includes("<!-- awesomux-inline-review -->"),
    )
    .sort((a, b) => (a.created_at > b.created_at ? -1 : 1))[0];
}

export async function deleteTemporaryReviewComment(comments, deleteComment) {
  const temporaryComment = findTemporaryReviewComment(comments);
  if (!temporaryComment) return null;

  await deleteComment(temporaryComment);
  return temporaryComment;
}

// ── Main (runs on direct execution) ──

const isMainModule =
import.meta.url === `file://${process.argv[1]}`;

if (isMainModule) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

async function main() {
  const logPath = process.env.OPENCODE_LOG;
  const token = process.env.GH_TOKEN;
  const repo = process.env.GITHUB_REPOSITORY;
  const prNumber = process.env.PR_NUMBER;
  const baseRef = process.env.BASE_REF || "main";
  const repoRoot = process.env.REPO_ROOT || process.cwd();

  if (!logPath || !token || !repo || !prNumber) {
    console.error(
      "Missing required env vars. Set OPENCODE_LOG, GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER.",
    );
    process.exit(1);
  }

  // 1. Extract the posted review from the log
  const logText = readFileSync(logPath, "utf-8");
  const reviewText = extractPostedRegion(logText);

  if (!reviewText) {
    console.log("No posted region found in log — skipping inline review.");
    return;
  }

  const reviewBody = extractReviewBody(reviewText);
  if (!reviewBody) {
    console.log("No '## Code Review' in posted region — skipping.");
    return;
  }

  const headers = {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${token}`,
    "X-GitHub-Api-Version": "2022-11-28",
  };

  // 2. Parse findings from the clean review body. OpenCode can print ANSI
  //    resets and runtime logs after the review text before the comment marker.
  const findings = parseFindings(reviewBody);

  // 3. Get the diff and parse hunks
  let diffText;
  let reviewedFiles;
  try {
    const baseRange = `origin/${baseRef}...HEAD`;
    diffText = execFileSync("git", ["diff", baseRange], {
      cwd: repoRoot,
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024,
    });
    reviewedFiles = execFileSync("git", ["diff", "--name-only", baseRange], {
      cwd: repoRoot,
      encoding: "utf-8",
    })
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
  } catch (err) {
    console.error(`Failed to get diff: ${err.message}`);
    process.exit(1);
  }

  const fileMap = parseDiffHunks(diffText);

  // 4. Map findings to inline comments vs. summary body
  const inlineComments = [];
  const outsideDiff = [];

  for (const finding of findings) {
    if (isCommentable(fileMap, finding.file, finding.line)) {
      inlineComments.push({
        path: finding.file,
        line: finding.line,
        side: "RIGHT",
        body: `**[${finding.severity}]** — ${finding.text}`,
      });
    } else {
      outsideDiff.push(finding);
    }
  }

  if (inlineComments.length === 0) {
    const comments = await listIssueComments({ repo, prNumber, headers });
    const temporaryComment = findTemporaryReviewComment(comments);
    if (!temporaryComment) {
      console.log("No temporary ## Code Review comment found; skipping inline review.");
      return;
    }

    const originalBody = temporaryComment.body ?? "";
    const updatedBody = upsertReviewedFilesSection(originalBody, reviewedFiles);
    if (updatedBody !== originalBody) {
      await githubAPI(
        `https://api.github.com/repos/${repo}/issues/comments/${temporaryComment.id}`,
        {
          method: "PATCH",
          headers: {
            ...headers,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ body: updatedBody }),
        },
      );
      console.log(
        `Updated native OpenCode review comment ${temporaryComment.id} with reviewed files.`,
      );
    }

    console.log("No inline comments found; left native OpenCode review comment in place.");
    return;
  }

  // 5. Build the review body
  const body = buildReviewBody({
    reviewBody,
    inlineCount: inlineComments.length,
    findingCount: findings.length,
    outsideDiff,
    reviewedFiles,
  });

  // 6. Post the PR Review
  const url = `https://api.github.com/repos/${repo}/pulls/${prNumber}/reviews`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...headers,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      body,
      event: "COMMENT",
      comments: inlineComments,
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error(`POST review failed: ${response.status} ${text}`);
    process.exit(1);
  }

  const result = await response.json();
  console.log(
    `Posted PR Review #${result.id} with ${inlineComments.length} inline comment(s).`,
  );
  console.log(`Review URL: ${result.html_url}`);

  // 7. Delete OpenCode's temporary top-level issue comment only after the PR
  //    Review exists, so a failed inline publish still leaves review feedback.
  const comments = await listIssueComments({ repo, prNumber, headers });
  const temporaryComment = await deleteTemporaryReviewComment(
    comments,
    (comment) =>
      githubAPI(
        `https://api.github.com/repos/${repo}/issues/comments/${comment.id}`,
        { method: "DELETE", headers },
      ),
  );
  if (!temporaryComment) {
    console.log("No temporary ## Code Review comment found to delete.");
    return;
  }
  console.log(`Deleted temporary review comment ${temporaryComment.id}.`);
}

async function listIssueComments({ repo, prNumber, headers }) {
  const comments = [];
  let url = `https://api.github.com/repos/${repo}/issues/${prNumber}/comments?per_page=100`;
  while (url) {
    const response = await fetch(url, { headers });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(`GET ${url} failed: ${response.status} ${text}`);
    }
    comments.push(...(await response.json()));
    const link = response.headers.get("link") || "";
    const next = link.match(/<([^>]+)>;\s*rel="next"/);
    url = next ? next[1] : "";
  }
  return comments;
}

async function githubAPI(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `${options.method || "GET"} ${url} failed: ${response.status} ${text}`,
    );
  }
  return response.status === 204 ? null : response.json();
}
