#!/usr/bin/env node

// Posts or updates a PR comment identified by a unique HTML comment marker.
// If a comment with the same marker already exists, it is updated in place;
// otherwise a new comment is created. Used by the opencode-review and
// opencode workflows for skip notices (docs-only, large diff, quota/usage
// limits, synchronize reminders).
//
// Env vars:
//   SKIP_MARKER       — HTML comment marker, e.g. "<!-- awesomux-opencode-skip -->"
//   SKIP_BODY         — comment body (without the marker; the script prepends it)
//   GH_TOKEN          — GitHub token with issues:write / pull-requests:write
//   GITHUB_REPOSITORY — owner/repo
//   ISSUE_NUMBER      — PR number

const marker = process.env.SKIP_MARKER;
const body = process.env.SKIP_BODY;
const repo = process.env.GITHUB_REPOSITORY;
const issueNumber = process.env.ISSUE_NUMBER;
const token = process.env.GH_TOKEN;

if (!marker || !body || !repo || !issueNumber || !token) {
  console.error(
    "Missing required env vars. Set SKIP_MARKER, SKIP_BODY, GH_TOKEN, GITHUB_REPOSITORY, ISSUE_NUMBER.",
  );
  process.exit(1);
}

const fullBody = `${marker}\n${body}`;

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
  let url = `https://api.github.com/repos/${repo}/issues/${issueNumber}/comments?per_page=100`;
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

async function main() {
  const comments = await listComments();
  const existing = comments.find(
    (comment) => comment.body && comment.body.includes(marker),
  );
  if (existing) {
    await githubAPI(
      `https://api.github.com/repos/${repo}/issues/comments/${existing.id}`,
      { method: "PATCH", body: JSON.stringify({ body: fullBody }) },
    );
  } else {
    await githubAPI(
      `https://api.github.com/repos/${repo}/issues/${issueNumber}/comments`,
      { method: "POST", body: JSON.stringify({ body: fullBody }) },
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
