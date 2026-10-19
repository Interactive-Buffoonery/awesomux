import test from "node:test";
import assert from "node:assert/strict";
import { validatePullRequest } from "../validate-pr-body.mjs";

const fullBody = `## Why
Make review safer.

## What's Included
- Add a trusted workflow.

## UI / UX
Not applicable because there is no visible change.

## Validation
- [x] \`node --test\` passed

## AI Assistance
- Assistance level: moderate

## Risk Notes
Workflow permissions were reviewed.

## Follow-ups
None.
`;

const rejectionCases = [
  ...["Why", "What's Included", "UI / UX", "Validation", "AI Assistance", "Risk Notes", "Follow-ups"].map((heading) => ({
    name: `missing ${heading}`,
    body: fullBody.split(/(?=^## )/m).filter((section) => !section.startsWith(`## ${heading}\n`)).join(""),
    error: heading,
  })),
  { name: "placeholder", body: fullBody.replace("Make review safer.", "<!-- explain why -->"), error: "placeholder" },
  { name: "template instruction", body: fullBody.replace("Make review safer.", "<!-- What changed, and why should this change exist? Lead with the reviewer-facing outcome. -->"), error: "placeholder" },
  { name: "footer filling a section", body: fullBody.replace("## Follow-ups\nNone.", "## Follow-ups\n") + "<!-- codesmith:footer -->\nManaged footer content.\n<!-- codesmith:autofix:enabled -->\n<!-- /codesmith:footer -->", error: "Follow-ups" },
];

test("rejects missing headings and template placeholders", () => {
  assert.equal(validatePullRequest({ body: fullBody, files: ["Sources/App.swift"] }).valid, true);
  for (const entry of rejectionCases) {
    assert.notEqual(entry.body, fullBody, entry.name);
    const result = validatePullRequest({ body: entry.body, files: ["Sources/App.swift"] });
    assert.equal(result.valid, false, entry.name);
    assert(result.errors.some((error) => error.includes(entry.error)), entry.name);
  }
});
