import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authorizeNativeCIRequest, parseNativeCICommand } from "../native-ci-request.mjs";

const validAuthorization = {
  actor: "serabi",
  maintainerLogins: ["serabi", "maintainer-two"],
  repository: "Interactive-Buffoonery/awesomux",
  issueIsPullRequest: true,
  pullRequest: {
    number: 129,
    state: "open",
    draft: false,
    head: {
      sha: "a".repeat(40),
      repo: { full_name: "Interactive-Buffoonery/awesomux" },
    },
  },
};
const requestScript = fileURLToPath(new URL("../native-ci-request.mjs", import.meta.url));

test("native CI commands map exact spellings to supported scopes", () => {
  assert.equal(parseNativeCICommand("/ci"), "all");
  assert.equal(parseNativeCICommand("/ci all"), "all");
  assert.equal(parseNativeCICommand("/ci unit"), "unit");
  assert.equal(parseNativeCICommand("/ci adapter"), "adapter");
  assert.equal(parseNativeCICommand("/ci system"), "system");
});

test("native CI rejects alternate spellings and trailing content", () => {
  for (const body of [
    "/CI",
    "/ci ",
    " /ci",
    "/ci\n",
    "/ci full",
    "/ci unit now",
    "/ci adapter\nplease",
  ]) {
    assert.equal(parseNativeCICommand(body), null, body);
  }
});

test("native CI authorization captures an immutable same-repository PR head", () => {
  assert.deepEqual(authorizeNativeCIRequest(validAuthorization), {
    headSHA: "a".repeat(40),
    prNumber: 129,
  });
});

test("native CI authorization rejects untrusted or ineligible requests", () => {
  const cases = [
    ["maintainer", { actor: "outsider" }],
    ["pull request comment", { issueIsPullRequest: false }],
    ["open", { pullRequest: { ...validAuthorization.pullRequest, state: "closed" } }],
    ["draft", { pullRequest: { ...validAuthorization.pullRequest, draft: true } }],
    [
      "same repository",
      {
        pullRequest: {
          ...validAuthorization.pullRequest,
          head: {
            ...validAuthorization.pullRequest.head,
            repo: { full_name: "fork-owner/awesomux" },
          },
        },
      },
    ],
    [
      "40-character",
      {
        pullRequest: {
          ...validAuthorization.pullRequest,
          head: { ...validAuthorization.pullRequest.head, sha: "abc123" },
        },
      },
    ],
  ];

  for (const [message, override] of cases) {
    const request = { ...validAuthorization, ...override };
    assert.throws(() => authorizeNativeCIRequest(request), new RegExp(message));
  }
});

test("native CI request helper exposes parsing and authorization as a CLI", () => {
  const parsed = spawnSync(process.execPath, [requestScript, "parse", "/ci unit"], {
    encoding: "utf8",
  });
  assert.equal(parsed.status, 0);
  assert.equal(parsed.stdout, "unit\n");

  const rejected = spawnSync(process.execPath, [requestScript, "parse", "/ci please"], {
    encoding: "utf8",
  });
  assert.equal(rejected.status, 2);

  const authorized = spawnSync(process.execPath, [requestScript, "authorize"], {
    input: JSON.stringify(validAuthorization),
    encoding: "utf8",
  });
  assert.equal(authorized.status, 0, authorized.stderr);
  assert.deepEqual(JSON.parse(authorized.stdout), {
    headSHA: "a".repeat(40),
    prNumber: 129,
  });
});
