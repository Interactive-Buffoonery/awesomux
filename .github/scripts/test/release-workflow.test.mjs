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
});

test("release workflow uploads and attaches the verification summary", () => {
  assert.match(workflow, /name: awesoMux-release-verification[\s\S]*?path: dist\/release\/awesoMux-\*\.verification\.json/);

  const draft = workflow.match(
    /\n      - name: Create draft GitHub Release[\s\S]*?(?=\n      - name: Publish rolling nightly prerelease)/,
  )?.[0];
  assert.ok(draft, "draft release step must exist");
  assert.match(draft, /dist\/release\/awesoMux-\$VERSION\.verification\.json/);
});

test("shared release build enables Sparkle only outside the nightly lane", () => {
  const build = workflow.match(
    /\n      - name: Build, sign, and notarize the release artifact[\s\S]*?(?=\n      - name: Verify release outputs before publication)/,
  )?.[0];
  assert.ok(build, "shared release build step must exist");
  assert.match(build, /SPARKLE_PUBLIC_ED_KEY: \$\{\{ github\.event_name != 'schedule' && vars\.SPARKLE_PUBLIC_ED_KEY \|\| '' \}\}/);
  assert.match(build, /if \[\[ "\$GITHUB_EVENT_NAME" == "schedule" \]\]; then[\s\S]*?build_release\.sh[\s\S]*?else[\s\S]*?build_release\.sh[\s\S]*?--enable-sparkle/);

  const nightlyBranch = build.match(/if \[\[ "\$GITHUB_EVENT_NAME" == "schedule" \]\]; then([\s\S]*?)else/)?.[1];
  assert.ok(nightlyBranch, "nightly build branch must be explicit");
  assert.doesNotMatch(nightlyBranch, /--enable-sparkle|SPARKLE_PUBLIC_ED_KEY/);
});

test("stable release generates one signed appcast without exposing its private key elsewhere", () => {
  const generation = workflow.match(
    /\n      - name: Generate signed appcast[\s\S]*?(?=\n      - name: Create draft GitHub Release)/,
  )?.[0];
  assert.ok(generation, "stable appcast generation step must exist");
  assert.match(generation, /if: inputs\.create_draft_release \|\| startsWith\(github\.ref, 'refs\/tags\/'\)/);
  assert.match(generation, /SPARKLE_PRIVATE_ED_KEY: \$\{\{ secrets\.SPARKLE_PRIVATE_ED_KEY \}\}/);
  assert.match(generation, /SPARKLE_PUBLIC_ED_KEY: \$\{\{ vars\.SPARKLE_PUBLIC_ED_KEY \}\}/);
  assert.match(generation, /\.build\/artifacts\/sparkle\/Sparkle\/bin\/generate_appcast/);
  assert.match(generation, /\[\[ -x "\$APPCAST_TOOL" \]\]/);
  assert.match(generation, /printf '%s' "\$SPARKLE_PRIVATE_ED_KEY" \|/);
  assert.match(generation, /--ed-key-file -/);
  assert.match(generation, /--maximum-deltas 0/);
  assert.match(generation, /--download-url-prefix "https:\/\/github\.com\/Interactive-Buffoonery\/awesomux\/releases\/download\/v\$RELEASE_VERSION\/"/);
  assert.match(generation, /-o "\$GITHUB_WORKSPACE\/appcast\.xml"/);
  assert.match(generation, /dist\/release\/awesoMux-\$RELEASE_VERSION\.dmg/);
  assert.doesNotMatch(generation, /generate_keys|echo "\$SPARKLE_PRIVATE_ED_KEY"|>[^|\n]*SPARKLE_PRIVATE_ED_KEY/);

  const outsideGeneration = workflow.replace(generation, "");
  assert.doesNotMatch(outsideGeneration, /SPARKLE_PRIVATE_ED_KEY/);

  const draft = workflow.match(
    /\n      - name: Create draft GitHub Release[\s\S]*?(?=\n      - name: Publish rolling nightly prerelease)/,
  )?.[0];
  assert.ok(draft, "draft release step must exist");
  assert.match(draft, /"appcast\.xml"/);

  const nightly = workflow.match(
    /\n      - name: Publish rolling nightly prerelease[\s\S]*?(?=\n      - name: Clean up signing keychain)/,
  )?.[0];
  assert.ok(nightly, "nightly publication step must exist");
  assert.doesNotMatch(nightly, /appcast|SPARKLE_PRIVATE_ED_KEY/);
});
