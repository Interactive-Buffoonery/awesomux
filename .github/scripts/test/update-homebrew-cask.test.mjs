import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const updateScript = join(repoRoot, "script/update_homebrew_cask.sh");

test("release helper rejects ambiguous self-update metadata without changing the cask", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  sha256 "${"a".repeat(64)}"
  auto_updates false
end
`;

  try {
    writeFileSync(caskPath, original);
    const result = spawnSync(
      "bash",
      [updateScript, "--version", "0.5.0", "--sha256", "b".repeat(64), "--cask", caskPath],
      { encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(caskPath, "utf8"), original);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("release helper rejects a malformed version without changing the cask", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  sha256 "${"a".repeat(64)}"
end
`;

  try {
    writeFileSync(caskPath, original);
    const result = spawnSync(
      "bash",
      [updateScript, "--version", "v0.5", "--sha256", "b".repeat(64), "--cask", caskPath],
      { encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(caskPath, "utf8"), original);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("release helper rejects a malformed checksum without changing the cask", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  sha256 "${"a".repeat(64)}"
end
`;

  try {
    writeFileSync(caskPath, original);
    const result = spawnSync(
      "bash",
      [updateScript, "--version", "0.5.0", "--sha256", "not-a-checksum", "--cask", caskPath],
      { encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(caskPath, "utf8"), original);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("release helper rejects an ambiguous cask without changing it", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  version "0.4.1"
  sha256 "${"a".repeat(64)}"
end
`;

  try {
    writeFileSync(caskPath, original);
    const result = spawnSync(
      "bash",
      [updateScript, "--version", "0.5.0", "--sha256", "b".repeat(64), "--cask", caskPath],
      { encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(caskPath, "utf8"), original);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});
