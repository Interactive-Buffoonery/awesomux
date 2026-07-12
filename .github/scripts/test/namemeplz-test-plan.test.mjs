#!/usr/bin/env node

import assert from "node:assert/strict";
import { test } from "node:test";

import { classifyTestPlan } from "../namemeplz-test-plan.mjs";

const changed = (filename, additions = 1, deletions = 0) => ({
  filename,
  additions,
  deletions,
});

test("documentation-only changes run guards without local commands", () => {
  const plan = classifyTestPlan({ files: [changed("docs/example.md", 20)] });
  assert.deepEqual(plan.automaticChecks, ["guards"]);
  assert.deepEqual(plan.localCommands, []);
});

test("core Swift changes require local Swift tests", () => {
  const plan = classifyTestPlan({
    files: [changed("Sources/AwesoMuxCore/Models/AgentState.swift", 20)],
  });
  assert.deepEqual(plan.automaticChecks, ["guards"]);
  assert.deepEqual(plan.localCommands, ["./script/swift-test.sh"]);
});

test("app changes require Swift tests and app verification", () => {
  const plan = classifyTestPlan({
    files: [changed("Sources/awesoMux/Views/ContentView.swift", 20)],
  });
  assert.deepEqual(plan.localCommands, [
    "./script/swift-test.sh",
    "./script/build_and_run.sh --verify",
  ]);
});

test("agent-hook script changes run focused automatic checks", () => {
  const plan = classifyTestPlan({
    files: [changed("script/agent-hooks/awesomux-agent-event", 8)],
  });
  assert.deepEqual(plan.automaticChecks, ["guards", "agent-hooks"]);
  assert.deepEqual(plan.localCommands, []);
});

test("agent-hook Swift changes also require local Swift tests", () => {
  const plan = classifyTestPlan({
    files: [changed("Sources/AwesoMuxAgentHookSupport/Event.swift", 8)],
  });
  assert.deepEqual(plan.automaticChecks, ["guards", "agent-hooks"]);
  assert.deepEqual(plan.localCommands, ["./script/swift-test.sh"]);
});

test("AMX changes emit exact local AMX commands", () => {
  const plan = classifyTestPlan({ files: [changed("vendor/zmx", 1)] });
  assert.deepEqual(plan.localCommands, [
    "(cd vendor/zmx && zig build test)",
    "./script/build_amx.sh",
    "./script/swift-test.sh",
    "./script/build_and_run.sh --verify",
  ]);
});

test("Ghostty changes emit the explicit local build", () => {
  const plan = classifyTestPlan({ files: [changed("vendor/ghostty", 1)] });
  assert.deepEqual(plan.localCommands, [
    "./script/build_ghostty_xcframework.sh",
    "./script/swift-test.sh",
    "./script/build_and_run.sh --verify",
  ]);
});

test("build infrastructure and large changes require local preflight", () => {
  const buildPlan = classifyTestPlan({ files: [changed("Package.swift", 5)] });
  assert.deepEqual(buildPlan.localCommands, ["./script/preflight.sh"]);
  const largePlan = classifyTestPlan({
    files: [changed("Sources/AwesoMuxCore/Large.swift", 701)],
  });
  assert.deepEqual(largePlan.localCommands, [
    "./script/swift-test.sh",
    "./script/preflight.sh",
  ]);
});

test("commands are deduplicated across many changed paths", () => {
  const plan = classifyTestPlan({
    files: [
      changed("Sources/awesoMux/Views/A.swift"),
      changed("Sources/awesoMux/Views/B.swift"),
    ],
  });
  assert.equal(plan.localCommands.filter((value) => value === "./script/swift-test.sh").length, 1);
});

test("missing file metadata is rejected", () => {
  assert.throws(() => classifyTestPlan({ files: [] }), /at least one/);
});
