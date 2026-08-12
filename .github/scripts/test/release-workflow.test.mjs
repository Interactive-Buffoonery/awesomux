import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/release.yml"), "utf8");

test("release workflow validates the DMG, checksum, and summary before publication", () => {
  const verification = workflow.match(
    /\n      - name: Verify release outputs before publication[\s\S]*?(?=\n      - name: Upload release DMG)/,
  )?.[0];
  assert.ok(verification, "release output verification step must exist");
  assert.match(verification, /DMG_PATH="dist\/release\/\$DMG_NAME"/);
  assert.match(verification, /CHECKSUM_PATH="\$DMG_PATH\.sha256"/);
  assert.match(verification, /SUMMARY_PATH="dist\/release\/awesoMux-\$RELEASE_VERSION\.verification\.json"/);
  assert.match(verification, /shasum -a 256 -c/);
  assert.match(verification, /\.build_number \| type == "string" and length > 0/);
  assert.match(verification, /\.gatekeeper_validation_passed == true/);
  assert.match(verification, /\.codesign_validation_passed == true/);
  assert.match(verification, /\.stapler_validation_passed == true/);
});

test("release workflow uploads and attaches the verification summary", () => {
  assert.match(workflow, /name: awesoMux-release-verification[\s\S]*?path: dist\/release\/awesoMux-\*\.verification\.json/);

  const draft = workflow.match(
    /\n      - name: Create draft GitHub Release[\s\S]*?(?=\n      - name: Publish rolling nightly prerelease)/,
  )?.[0];
  assert.ok(draft, "draft release step must exist");
  assert.match(draft, /dist\/release\/awesoMux-\$VERSION\.verification\.json/);
});
