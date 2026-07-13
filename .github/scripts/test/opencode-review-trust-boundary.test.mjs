#!/usr/bin/env node

// Structural regression test for the automatic OpenCode review trust boundary.
// Run: node --test .github/scripts/test/opencode-review-trust-boundary.test.mjs
//
// The automatic review workflow holds id-token:write, pull-requests/issues
// write, GITHUB_TOKEN, and SYNTHETIC_API_KEY. PR-controlled helper code must
// never execute under that privilege. Helpers run only from the trusted
// default-branch checkout at _trusted/ (same pattern as opencode.yml).

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "../../..");
const workflowPath = join(repoRoot, ".github/workflows/opencode-review.yml");
const commentWorkflowPath = join(repoRoot, ".github/workflows/opencode.yml");
const actionPath = join(repoRoot, ".github/actions/run-opencode/action.yml");
const configPath = join(repoRoot, ".opencode/opencode.json");
const runnerPath = join(
  repoRoot,
  ".github/actions/run-opencode/run-opencode.sh",
);
const appendReviewedFilesPath = join(
  repoRoot,
  ".github/scripts/append-reviewed-files.mjs",
);
const workflow = readFileSync(workflowPath, "utf-8");
const commentWorkflow = stripYamlComments(
  readFileSync(commentWorkflowPath, "utf-8"),
);
const action = stripYamlComments(readFileSync(actionPath, "utf-8"));
const config = JSON.parse(readFileSync(configPath, "utf-8"));
const runner = readFileSync(runnerPath, "utf-8");
const appendReviewedFiles = readFileSync(appendReviewedFilesPath, "utf-8");

/** Strip YAML comments so structural checks do not match examples in comments. */
function stripYamlComments(source) {
  return source
    .split("\n")
    .map((line) => {
      // Keep full-line comments out; inline `#` in strings is rare in these
      // workflows and not needed for path assertions.
      const hash = line.indexOf("#");
      if (hash === -1) return line;
      const before = line.slice(0, hash);
      // If the hash is inside a quoted string this is imperfect, but workflow
      // path assertions only need step `run`/`uses` lines.
      if ((before.match(/'/g) || []).length % 2 === 1) return line;
      if ((before.match(/"/g) || []).length % 2 === 1) return line;
      return before;
    })
    .join("\n");
}

const body = stripYamlComments(workflow);

describe("opencode review concurrency", () => {
  test("isolates automatic and comment-triggered review runs", () => {
    assert.match(
      body,
      /group:\s*opencode-automatic-review-\$\{\{\s*github\.event\.pull_request\.number\s*\}\}/,
      "automatic reviews must cancel only automatic reviews for the same PR",
    );
    assert.match(
      commentWorkflow,
      /group:\s*opencode-manual-review-\$\{\{\s*github\.event\.issue\.number\s*\}\}/,
      "manual reviews must cancel only manual reviews for the same PR",
    );
    assert.doesNotMatch(
      body,
      /group:\s*opencode-review-/,
      "automatic reviews must not share the legacy cross-workflow group",
    );
    assert.doesNotMatch(
      commentWorkflow,
      /group:\s*opencode-review-/,
      "comment events must not share the legacy cross-workflow group",
    );
    assert.match(body, /cancel-in-progress:\s*true/);
    assert.match(commentWorkflow, /cancel-in-progress:\s*true/);
  });
});

describe("opencode automatic review eligibility", () => {
  test("reviews only explicit non-draft readiness events", () => {
    assert.match(
      body,
      /types:\s*\[opened, reopened, ready_for_review\]/,
      "automatic reviews must not subscribe to draft conversion events",
    );
    assert.match(
      body,
      /contains\(fromJSON\('\["opened", "reopened", "ready_for_review"\]'\), github\.event\.action\)/,
      "the job must independently reject unexpected activity types",
    );
    assert.match(
      body,
      /github\.event\.pull_request\.draft\s*==\s*false/,
      "draft pull requests must not enter the review job",
    );
  });

  test("skips an automatic rerun when Actions already reviewed the PR", () => {
    assert.match(body, /name:\s*Check for an existing automatic review/);
    assert.match(body, /awesomux-opencode-review/);
    assert.match(
      body,
      /startsWith\("## Code Review"\)|startswith\("## Code Review"\)/,
    );
    assert.match(
      body,
      /name:\s*Run opencode review\s*\n\s*if:\s*steps\.existing_review\.outputs\.skip != 'true'[^\n]*\n\s*id:\s*opencode/,
      "the paid review step must be gated by the existing-review check",
    );
  });

  test("upserts one marked Actions review and removes duplicates", () => {
    assert.match(runner, /review_marker='<!-- awesomux-opencode-review -->'/);
    assert.match(runner, /issues\/comments\/\$\{review_comment_ids\[0\]\}/);
    assert.match(runner, /--method PATCH/);
    assert.match(runner, /for duplicate_id in/);
    assert.match(runner, /--method DELETE/);
  });
});

describe("opencode review tool output", () => {
  test("keeps normal pull request diffs visible within a bounded preview", () => {
    assert.equal(config.tool_output?.max_lines, 2000);
    assert.equal(config.tool_output?.max_bytes, 262144);
  });

  test("scopes the larger bounded preview to explicit manual review", () => {
    assert.match(body, /large_diff_mode:\s*skip/);
    assert.match(commentWorkflow, /max_diff_lines:\s*["']10000["']/);
    assert.match(commentWorkflow, /max_diff_bytes:\s*["']524288["']/);
    assert.match(
      commentWorkflow,
      /"tool_output":\{"max_lines":10000,"max_bytes":524288\}/,
    );
    assert.doesNotMatch(body, /max_diff_lines:\s*["']10000["']/);
  });
});

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function opencodeReviewStep() {
  const match = body.match(
    /-\s+name:\s*Run opencode review[\s\S]*?(?=\n\s*-\s+name:|\n[A-Za-z]|$)/,
  );
  assert.ok(match, "missing Run opencode review step");
  return match[0];
}

describe("opencode-review trusted-helper checkout", () => {
  test("checks out trusted helpers into _trusted from the default branch", () => {
    assert.match(
      body,
      /path:\s*_trusted/,
      "trusted helpers must land under path: _trusted",
    );
    assert.match(
      body,
      /ref:\s*\$\{\{\s*github\.event\.repository\.default_branch\s*\}\}/,
      "trusted helpers must come from the repository default branch",
    );
    assert.match(
      body,
      /repository:\s*\$\{\{\s*github\.repository\s*\}\}/,
      "trusted helpers must come from the base repository, not a PR head repo",
    );
  });

  test("excludes the helper checkout from git status (no dirty writeback path)", () => {
    assert.match(
      body,
      /echo\s+"_trusted\/"\s+>>\s+\.git\/info\/exclude/,
      "must hide _trusted/ from git status so opencode writeback stays clean",
    );
  });

  test("runs review guards, posting scripts, and local action from _trusted only", () => {
    const trustedScripts = [
      "_trusted/.github/scripts/compute-review-guards.mjs",
      "_trusted/.github/scripts/post-skip-comment.mjs",
      "_trusted/.github/scripts/post-inline-review.mjs",
    ];
    for (const script of trustedScripts) {
      assert.match(
        body,
        new RegExp(
          `(?:^|\\n)\\s*run:\\s*node\\s+${escapeRegExp(script)}(?:\\s|$)`,
          "m",
        ),
        `must execute trusted helper: node ${script}`,
      );
    }

    assert.match(
      body,
      /uses:\s*\.\/_trusted\/\.github\/actions\/run-opencode/,
      "local run-opencode action must load from the trusted helper checkout",
    );
  });

  test("does not execute PR-tree copies of workflow helpers", () => {
    // Untrusted PR working tree paths that would reintroduce the vulnerability.
    const forbiddenExecutablePaths = [
      /(?:^|\n)\s*run:\s*node\s+\.github\/scripts\/compute-review-guards\.mjs\b/m,
      /(?:^|\n)\s*run:\s*node\s+\.github\/scripts\/post-skip-comment\.mjs\b/m,
      /(?:^|\n)\s*run:\s*node\s+\.github\/scripts\/post-inline-review\.mjs\b/m,
      /(?:^|\n)\s*uses:\s*\.\/\.github\/actions\/run-opencode\b/m,
      /(?:^|\n)\s*uses:\s*\.\/\.github\/actions\/run-opencode\//m,
    ];

    for (const pattern of forbiddenExecutablePaths) {
      assert.equal(
        pattern.test(body),
        false,
        `must not execute PR-controlled helper matching ${pattern}`,
      );
    }
  });

  test("fetches the PR head as passive data without checking it out", () => {
    assert.match(
      body,
      /refs\/pull\/\$\{PR_NUMBER\}\/head:refs\/remotes\/pull\/\$\{PR_NUMBER\}\/head/,
      "automatic review must fetch the PR head into a passive remote ref",
    );
    assert.doesNotMatch(
      body,
      /ref:\s*\$\{\{[^\n]*pull_request\.head/,
      "automatic review must not check out the PR head",
    );
    assert.match(
      body,
      /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}[\s\S]*?credential\.helper=!f\(\)/,
      "automatic passive fetch must use the command-scoped token helper",
    );
    assert.match(
      body,
      /EXPECTED_HEAD_SHA:\s*\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}[\s\S]*?actual_head_sha[\s\S]*?!=\s*"\$EXPECTED_HEAD_SHA"/,
      "automatic fetch must fail if the PR ref no longer matches the event SHA",
    );
    assert.match(
      body,
      /base_range="\$\{BASE_SHA\}\.\.\.\$\{HEAD_SHA\}"/,
      "automatic review range must end at the immutable event head SHA",
    );
    const checkoutCount = (body.match(/uses:\s*actions\/checkout@/g) || [])
      .length;
    assert.ok(
      checkoutCount >= 2,
      `expected trusted root and helper checkouts, found ${checkoutCount}`,
    );
  });

  test("fork-shaped trusted helper pin: helpers never come from the PR head ref", () => {
    // Even if a future change adds head.sha checkout for the PR tree, the
    // trusted path block must not pin helpers to the PR head.
    const trustedBlockMatch = body.match(
      /Checkout trusted workflow helpers[\s\S]*?(?=\n\s*-\s+name:|\n\s*#\s*[A-Z]|\n[A-Za-z]|$)/,
    );
    assert.ok(trustedBlockMatch, "missing trusted helper checkout step");
    const trustedBlock = trustedBlockMatch[0];
    assert.doesNotMatch(
      trustedBlock,
      /pull_request\.head\.(sha|ref|repo)/,
      "trusted helper checkout must not use PR head coordinates",
    );
    assert.match(
      trustedBlock,
      /default_branch/,
      "trusted helper checkout must pin default_branch",
    );
  });

  test("mirrors the comment-triggered trusted-helper pattern", () => {
    // Keep automatic review aligned with the hardened /codereview workflow.
    assert.match(
      commentWorkflow,
      /path:\s*_trusted/,
      "comment workflow still uses _trusted (reference pattern drifted)",
    );
    assert.match(
      commentWorkflow,
      /uses:\s*\.\/_trusted\/\.github\/actions\/run-opencode/,
      "comment workflow still runs the trusted local action",
    );
    assert.match(
      body,
      /uses:\s*\.\/_trusted\/\.github\/actions\/run-opencode/,
      "automatic review must use the same trusted local action path",
    );
    assert.match(
      commentWorkflow,
      /refs\/pull\/\$\{PR_NUMBER\}\/head:refs\/remotes\/pull\/\$\{PR_NUMBER\}\/head/,
      "comment review must fetch the PR head as passive data",
    );
    assert.doesNotMatch(
      commentWorkflow,
      /ref:\s*\$\{\{[^\n]*pull_request\.head/,
      "comment review must not check out the PR head",
    );
    assert.match(
      commentWorkflow,
      /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}[\s\S]*?credential\.helper=!f\(\)/,
      "comment passive fetch must use the command-scoped token helper",
    );
    assert.match(
      commentWorkflow,
      /EXPECTED_HEAD_SHA:\s*\$\{\{\s*steps\.pull_request\.outputs\.head_sha\s*\}\}[\s\S]*?actual_head_sha[\s\S]*?!=\s*"\$EXPECTED_HEAD_SHA"/,
      "comment fetch must fail if the PR ref moves after API resolution",
    );
    assert.match(
      commentWorkflow,
      /base_range="\$\{BASE_SHA\}\.\.\.\$\{HEAD_SHA\}"/,
      "comment review range must end at the captured immutable head SHA",
    );
  });

  test("disables PR-tree OpenCode project config and loads trusted .opencode", () => {
    // Keep the privileged run pinned to the separately checked-out trusted
    // configuration rather than whichever repository config happens to be in
    // the process working directory (OpenCode v1.17.8 Flag + ConfigPaths).
    // Scope assertions to the privileged step so pins cannot drift onto an
    // unrelated step while this test stays green.
    const opencodeStep = opencodeReviewStep();
    assert.match(
      opencodeStep,
      /OPENCODE_DISABLE_PROJECT_CONFIG:\s*["']?1["']?/,
      "Run opencode review must set OPENCODE_DISABLE_PROJECT_CONFIG=1",
    );
    assert.match(
      opencodeStep,
      /OPENCODE_CONFIG_DIR:\s*\$\{\{\s*github\.workspace\s*\}\}\/_trusted\/\.opencode/,
      "Run opencode review must point OPENCODE_CONFIG_DIR at trusted .opencode",
    );
    assert.match(
      opencodeStep,
      /SYNTHETIC_API_KEY:\s*\$\{\{\s*secrets\.SYNTHETIC_API_KEY\s*\}\}/,
      "config pins must co-locate with SYNTHETIC_API_KEY on the review step",
    );
  });

  test("keeps automatic review limited to allowlisted same-repository authors", () => {
    assert.match(
      body,
      /head\.repo\.full_name\s*==\s*github\.repository/,
      "automatic review must reject fork heads",
    );
    assert.match(
      body,
      /MAINTAINER_LOGINS_JSON[\s\S]*?pull_request\.user\.login/,
      "automatic review must authorize the PR author",
    );
  });

  test("runs OpenCode without its checkout-capable GitHub wrapper", () => {
    assert.match(
      runner,
      /opencode --pure run --format json --model/,
      "trusted runner must use non-interactive opencode run",
    );
    assert.doesNotMatch(
      runner,
      /opencode github run/,
      "OpenCode's GitHub wrapper checks out the PR branch and must not run",
    );
  });

  test("recovers narration in-session before one fresh fallback", () => {
    assert.match(runner, /continue_session=true/);
    assert.match(runner, /mode="continuation"/);
    assert.match(runner, /mode="fresh fallback"/);
    assert.match(runner, /for attempt in 1 2 3/);
  });

  test("bounds exact diffs and lets automatic review skip oversized previews", () => {
    assert.match(runner, /git diff "\$BASE_RANGE" -- > "\$diff_probe"/);
    assert.match(runner, /MAX_DIFF_LINES:-2000/);
    assert.match(runner, /MAX_DIFF_BYTES:-262144/);
    assert.match(
      body,
      /BASE_RANGE:\s*\$\{\{\s*steps\.review_context\.outputs\.base_range\s*\}\}/,
    );
    assert.match(
      commentWorkflow,
      /BASE_RANGE:\s*\$\{\{\s*steps\.review_context\.outputs\.base_range\s*\}\}/,
    );
    assert.match(action, /diff_too_large:/);
    assert.match(runner, /LARGE_DIFF_MODE:-fail/);
    assert.match(body, /steps\.opencode\.outputs\.diff_too_large == 'true'/);
    assert.match(body, /awesomux-opencode-skip/);
  });

  test("publishes safe per-attempt telemetry to the Actions summary", () => {
    assert.match(runner, /### OpenCode review telemetry/);
    assert.match(runner, /Tool output truncated/);
    assert.match(runner, /summarize-log\.mjs/);
    assert.doesNotMatch(
      runner,
      /cat "\$attempt_log" >> "\$GITHUB_STEP_SUMMARY"/,
    );
  });

  test("keeps comment-triggered permission tied to the allowlisted command author", () => {
    assert.match(
      commentWorkflow,
      /github\.event\.comment\.body\s*==\s*['"]\/codereview['"]/,
      "manual review must require the exact /codereview command",
    );
    assert.match(
      commentWorkflow,
      /MAINTAINER_LOGINS_JSON[\s\S]*?github\.actor/,
      "manual review must authorize the allowlisted command author",
    );
  });

  test("passes the target PR number for explicit review publication", () => {
    assert.match(
      action,
      /issue_number:[\s\S]*?required:\s*true/,
      "trusted action must require an explicit issue number",
    );
    assert.match(
      body,
      /issue_number:\s*\$\{\{\s*github\.event\.pull_request\.number\s*\}\}/,
    );
    assert.match(
      commentWorkflow,
      /issue_number:\s*\$\{\{\s*github\.event\.issue\.number\s*\}\}/,
    );
    assert.match(
      runner,
      /issues\/\$\{ISSUE_NUMBER\}\/comments/,
      "trusted runner must publish the validated review explicitly",
    );
  });

  test("acknowledges accepted review commands with an eyes reaction", () => {
    assert.match(commentWorkflow, /name:\s*Acknowledge review command/);
    assert.match(
      commentWorkflow,
      /issues\/comments\/\$\{COMMENT_ID\}\/reactions[\s\S]*?-f content=eyes/,
    );
  });

  test("accepts the immutable review range without requiring a base ref", () => {
    assert.match(
      appendReviewedFiles,
      /process\.env\.BASE_RANGE\s*\|\|\s*\(baseRef\s*\?/,
      "reviewed-files helper must prefer the exact range",
    );
    assert.doesNotMatch(
      appendReviewedFiles,
      /!baseRef\s*\|\|/,
      "BASE_REF must remain optional when BASE_RANGE is supplied",
    );
  });

  test("installs a versioned OpenCode archive only after SHA-256 verification", () => {
    assert.doesNotMatch(action, /opencode\.ai\/install|curl[^\n]*\|\s*bash/);
    assert.match(
      action,
      /releases\/download\/v\$\{OPENCODE_VERSION\}\/opencode-linux-x64\.tar\.gz/,
    );
    assert.match(action, /OPENCODE_ARCHIVE_SHA256:\s*["']?[a-f0-9]{64}["']?/);
    assert.match(action, /sha256sum --check --strict/);
  });
});
