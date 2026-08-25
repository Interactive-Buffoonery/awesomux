import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const updateScript = join(repoRoot, "script/update_homebrew_cask.sh");

test("release helper updates one cask version and checksum and enables self-updates", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  sha256 "${"a".repeat(64)}"

  url "https://example.test/awesoMux-#{version}.dmg"
end
`;
  const expected = original
    .replace('version "0.4.0"', 'version "0.5.0"')
    .replace(`sha256 "${"a".repeat(64)}"`, `sha256 "${"b".repeat(64)}"\n  auto_updates true`);

  try {
    writeFileSync(caskPath, original);
    const result = spawnSync(
      "bash",
      [updateScript, "--version", "0.5.0", "--sha256", "b".repeat(64), "--cask", caskPath],
      { encoding: "utf8" },
    );

    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(caskPath, "utf8"), expected);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test("release helper preserves exactly one self-update declaration on repeated runs", () => {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-homebrew-cask-"));
  const caskPath = join(fixtureRoot, "awesomux.rb");
  const original = `cask "awesomux" do
  version "0.4.0"
  sha256 "${"a".repeat(64)}"
  auto_updates true

  url "https://example.test/awesoMux-#{version}.dmg"
end
`;

  try {
    writeFileSync(caskPath, original);
    for (let iteration = 0; iteration < 2; iteration += 1) {
      const result = spawnSync(
        "bash",
        [updateScript, "--version", "0.5.0", "--sha256", "b".repeat(64), "--cask", caskPath],
        { encoding: "utf8" },
      );
      assert.equal(result.status, 0, result.stderr);
    }

    const updated = readFileSync(caskPath, "utf8");
    assert.equal(updated.match(/^  auto_updates true$/gm)?.length, 1);
    assert.equal(updated, original
      .replace('version "0.4.0"', 'version "0.5.0"')
      .replace(`sha256 "${"a".repeat(64)}"`, `sha256 "${"b".repeat(64)}"`));
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

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
