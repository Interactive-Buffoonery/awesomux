#!/usr/bin/env node

import { readFileSync } from "node:fs";

export const AUTOMATIC_CHECK_ORDER = ["guards", "agent-hooks"];
export const LOCAL_COMMAND_ORDER = [
  "(cd vendor/zmx && zig build test)",
  "./script/build_amx.sh",
  "./script/build_ghostty_xcframework.sh",
  "./script/swift-test.sh",
  "./script/build_and_run.sh --verify",
  "./script/preflight.sh",
];

const documentationPath = /^(docs\/|README(?:\.|$)|CHANGELOG(?:\.|$)|CONTRIBUTING(?:\.|$)|CODE_OF_CONDUCT(?:\.|$)|SUPPORT(?:\.|$)|GOVERNANCE(?:\.|$)|.*\.(?:md|png|jpe?g|gif|webp|svg|pdf)$)/i;
const testPath = /^Tests\//;
const swiftRuntimePath = /^(Sources\/|Resources\/|Tests\/)/;
const appPath = /^(Sources\/awesoMux\/|Resources\/|Tests\/awesoMuxTests\/)/;
const agentHookPath = /^(script\/agent-hooks\/|Sources\/AwesoMuxAgentHook|Sources\/AwesoMuxAgentHookSupport|Tests\/AwesoMuxAgentHookSupportTests\/)/;
const amxPath = /^(vendor\/zmx(?:\/|$)|script\/(?:build_amx|amx-|amx\.)|Sources\/awesoMux\/Services\/AmxBackend\.swift|Tests\/awesoMuxTests\/AmxBackendTests\.swift|docs\/amx-automation\.md)/;
const ghosttyPath = /^(vendor\/ghostty(?:\/|$)|Sources\/GhosttyKit\/|Sources\/awesoMux\/.*Ghostty|Tests\/awesoMuxTests\/.*Ghostty|script\/(?:build_ghostty|ensure_ghostty|ghostty_)|docs\/ghostty-integration\.md)/;
const preflightPath = /^(Package\.swift|Package\.resolved|\.gitmodules|\.github\/workflows\/|script\/(?:preflight|build_and_run|prepare_public_seed)\.sh|docs\/(?:releasing|adr\/0019-))/;

function ordered(values, order) {
  return order.filter((value) => values.has(value));
}

export function classifyTestPlan({ files }) {
  if (!Array.isArray(files) || files.length === 0) {
    throw new Error("at least one changed file is required");
  }

  const automatic = new Set(["guards"]);
  const local = new Set();
  const reasons = [];
  const substantive = files.filter(
    (file) => !documentationPath.test(file.filename) && !testPath.test(file.filename),
  );
  const substantiveLines = substantive.reduce(
    (total, file) => total + file.additions + file.deletions,
    0,
  );

  if (files.every((file) => documentationPath.test(file.filename))) {
    reasons.push("all changed paths are documentation or static assets");
  }

  for (const file of files) {
    const path = file.filename;
    if (agentHookPath.test(path)) {
      automatic.add("agent-hooks");
      reasons.push(`${path} selects the automatic agent-hook checks`);
    }
    if (preflightPath.test(path)) {
      local.add("./script/preflight.sh");
      reasons.push(`${path} requires maintainer preflight`);
    }
    if (amxPath.test(path)) {
      local.add("(cd vendor/zmx && zig build test)");
      local.add("./script/build_amx.sh");
      local.add("./script/swift-test.sh");
      local.add("./script/build_and_run.sh --verify");
      reasons.push(`${path} requires maintainer AMX validation`);
    }
    if (ghosttyPath.test(path)) {
      local.add("./script/build_ghostty_xcframework.sh");
      local.add("./script/swift-test.sh");
      local.add("./script/build_and_run.sh --verify");
      reasons.push(`${path} requires a maintainer Ghostty build`);
    }
    if (appPath.test(path)) {
      local.add("./script/swift-test.sh");
      local.add("./script/build_and_run.sh --verify");
      reasons.push(`${path} requires maintainer Swift and app verification`);
    } else if (swiftRuntimePath.test(path)) {
      local.add("./script/swift-test.sh");
      reasons.push(`${path} requires maintainer Swift tests`);
    }
  }

  if (substantiveLines > 700 || substantive.length > 15) {
    local.add("./script/preflight.sh");
    reasons.push(
      `cross-cutting size requires maintainer preflight (${substantiveLines} substantive lines across ${substantive.length} files)`,
    );
  }

  if (reasons.length === 0) {
    reasons.push("unclassified paths fail closed to repository guards");
  }

  const automaticChecks = ordered(automatic, AUTOMATIC_CHECK_ORDER);
  const localCommands = ordered(local, LOCAL_COMMAND_ORDER);
  return {
    schemaVersion: 2,
    automaticChecks,
    localCommands,
    estimatedMinutes: automaticChecks.includes("agent-hooks") ? 4 : 2,
    substantiveLines,
    substantiveFiles: substantive.length,
    reasons: [...new Set(reasons)],
  };
}

function main() {
  const [filesPath] = process.argv.slice(2);
  if (!filesPath) {
    throw new Error("usage: namemeplz-test-plan.mjs <files.json>");
  }
  const files = JSON.parse(readFileSync(filesPath, "utf8"));
  process.stdout.write(`${JSON.stringify(classifyTestPlan({ files }))}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
