#!/usr/bin/env node

import { chmodSync, readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath, rawLimit = "65536"] = process.argv.slice(2);
const maxBytes = Number(rawLimit);
const truncationSuffix = Buffer.from(
  "\n[PR metadata truncated by the trusted runner.]\n",
);

if (
  !inputPath ||
  !outputPath ||
  !Number.isSafeInteger(maxBytes) ||
  maxBytes < truncationSuffix.length
) {
  console.error(
    "usage: prepare-opencode-context.mjs <pull-request-json> <output> [max-bytes]",
  );
  process.exit(1);
}

const source = JSON.parse(readFileSync(inputPath, "utf8"));
const pullRequest = source.pull_request ?? source;
if (typeof pullRequest.title !== "string") {
  throw new Error("pull-request JSON is missing a string title");
}

const context = [
  "PR title:",
  pullRequest.title,
  "",
  "PR body:",
  typeof pullRequest.body === "string" ? pullRequest.body : "",
  "",
].join("\n");
const encoded = Buffer.from(context, "utf8");
let bounded = encoded;

if (encoded.length > maxBytes) {
  const prefixLimit = maxBytes - truncationSuffix.length;
  let end = prefixLimit;
  while (end > 0 && (encoded[end] & 0xc0) === 0x80) end -= 1;
  bounded = Buffer.concat([encoded.subarray(0, end), truncationSuffix]);
}

writeFileSync(outputPath, bounded, { mode: 0o600 });
chmodSync(outputPath, 0o600);
