#!/usr/bin/env node

// Appends a "Files reviewed" section to the most recent ## Code Review
// comment posted by github-actions[bot]. Idempotent: uses a marker so
// re-running the step updates the section rather than duplicating it.
//
// Env vars:
//   GH_TOKEN          — GitHub token with pull-requests:write
//   GITHUB_REPOSITORY — owner/repo
//   PR_NUMBER         — PR number
//   BASE_REF          — base branch name (e.g. "main")
//   BASE_RANGE        — optional explicit git diff range
//                       (e.g. "refs/remotes/base/main...HEAD")
//   REPO_ROOT         — repository checkout root (for git diff)

const repo = process.env.GITHUB_REPOSITORY;
const prNumber = process.env.PR_NUMBER;
const baseRef = process.env.BASE_REF;
const repoRoot = process.env.REPO_ROOT;
const baseRange = process.env.BASE_RANGE || (baseRef ? `origin/${baseRef}...HEAD` : "");
const token = process.env.GH_TOKEN;

if (!repo || !prNumber || !baseRange || !repoRoot || !token) {
  console.error(
    "Missing required env vars. Set GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, REPO_ROOT, and either BASE_RANGE or BASE_REF.",
  );
  process.exit(1);
}

const MARKER = "<!-- awesomux-reviewed-files -->";

const headers = {
  Accept: "application/vnd.github+json",
  Authorization: `Bearer ${token}`,
  "X-GitHub-Api-Version": "2022-11-28",
};

async function githubAPI(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { ...headers, ...(options.headers || {}) },
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `${options.method || "GET"} ${url} failed: ${response.status} ${text}`,
    );
  }
  return response.status === 204 ? null : response.json();
}

async function listComments() {
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

async function getChangedFiles() {
  const { execFileSync } = await import("node:child_process");
  const output = execFileSync(
    "git",
    ["diff", "--name-only", baseRange],
    { cwd: repoRoot, encoding: "utf-8" },
  );
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function buildFilesSection(files) {
  const list = files.map((f) => `- \`${f}\``).join("\n");
  return `${MARKER}\n\n<details><summary>Files reviewed (${files.length})</summary>\n\n${list}\n\n</details>`;
}

async function main() {
  const files = await getChangedFiles();
  if (files.length === 0) {
    console.log("No changed files found; skipping.");
    return;
  }

  const comments = await listComments();
  // Find the most recent comment by github-actions[bot] that contains
  // a ## Code Review heading at the start of a line (may have preamble
  // text before it, but not a mid-paragraph mention).
  const reviewComment = comments
    .filter(
      (c) =>
        c.user?.login === "github-actions[bot]" &&
        /^## Code Review/m.test(c.body ?? ""),
    )
    .sort((a, b) => (a.created_at > b.created_at ? -1 : 1))[0];

  if (!reviewComment) {
    console.log("No ## Code Review comment found; skipping.");
    return;
  }

  const filesSection = buildFilesSection(files);
  let body = reviewComment.body;

  if (body.includes(MARKER)) {
    // Replace existing files section.
    body = body.replace(
      new RegExp(`${MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}.*`, "s"),
      filesSection,
    );
  } else {
    body = `${body}\n\n${filesSection}`;
  }

  await githubAPI(
    `https://api.github.com/repos/${repo}/issues/comments/${reviewComment.id}`,
    { method: "PATCH", body: JSON.stringify({ body }) },
  );

  console.log(`Appended ${files.length} reviewed files to comment ${reviewComment.id}.`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
