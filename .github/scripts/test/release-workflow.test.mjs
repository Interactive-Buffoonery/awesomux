import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/release.yml"), "utf8");
const appcastValidator = join(repoRoot, ".github/scripts/validate_appcast.sh");
const expectedDmgURL = "https://github.com/Interactive-Buffoonery/awesomux/releases/download/v9.9.9/awesoMux-9.9.9.dmg";
const canValidateAppcast = existsSync("/usr/bin/xmllint");

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

test("release lanes validate only the Sparkle keys they need before checkout", () => {
  const publicValidation = workflow.match(
    /\n      - name: Verify Sparkle public key is present[\s\S]*?(?=\n      - name: Verify appcast signing secret is present)/,
  )?.[0];
  assert.ok(publicValidation, "early Sparkle public-key validation step must exist");
  assert.match(publicValidation, /if: github\.event_name != 'schedule'/);
  assert.match(publicValidation, /SPARKLE_PUBLIC_ED_KEY: \$\{\{ vars\.SPARKLE_PUBLIC_ED_KEY \}\}/);
  assert.doesNotMatch(publicValidation, /SPARKLE_PRIVATE_ED_KEY/);

  const privateValidation = workflow.match(
    /\n      - name: Verify appcast signing secret is present[\s\S]*?(?=\n      - name: Resolve release collisions)/,
  )?.[0];
  assert.ok(privateValidation, "early appcast private-key validation step must exist");
  assert.match(privateValidation, /if: inputs\.create_draft_release \|\| startsWith\(github\.ref, 'refs\/tags\/'\)/);
  assert.match(privateValidation, /SPARKLE_PRIVATE_ED_KEY: \$\{\{ secrets\.SPARKLE_PRIVATE_ED_KEY \}\}/);
  assert.doesNotMatch(privateValidation, /SPARKLE_PUBLIC_ED_KEY/);

  const releaseJob = workflow.indexOf("\n  release:\n");
  const releaseCheckout = workflow.indexOf("- name: Checkout repository", releaseJob);
  assert.ok(workflow.indexOf("- name: Verify Sparkle public key is present") < releaseCheckout);
  assert.ok(workflow.indexOf("- name: Verify appcast signing secret is present") < releaseCheckout);
});

test("shared release build enables Sparkle only outside the nightly lane", () => {
  const build = workflow.match(
    /\n      - name: Build, sign, and notarize the release artifact[\s\S]*?(?=\n      - name: Verify release outputs before publication)/,
  )?.[0];
  assert.ok(build, "shared release build step must exist");
  assert.match(build, /SPARKLE_PUBLIC_ED_KEY: \$\{\{ github\.event_name != 'schedule' && vars\.SPARKLE_PUBLIC_ED_KEY \|\| '' \}\}/);
  assert.match(build, /--use-staged-bundle/);
  assert.match(build, /if \[\[ "\$GITHUB_EVENT_NAME" == "schedule" \]\]; then[\s\S]*?build_release\.sh[\s\S]*?else[\s\S]*?build_release\.sh[\s\S]*?--enable-sparkle/);

  const nightlyBranch = build.match(/if \[\[ "\$GITHUB_EVENT_NAME" == "schedule" \]\]; then([\s\S]*?)else/)?.[1];
  assert.ok(nightlyBranch, "nightly build branch must be explicit");
  assert.doesNotMatch(nightlyBranch, /--enable-sparkle|SPARKLE_PUBLIC_ED_KEY/);
});

test("release workflow stages the final bundle before importing credentials", () => {
  const staging = workflow.match(
    /\n      - name: Stage release bundle before signing material exists[\s\S]*?(?=\n      - name: Import signing identity)/,
  )?.[0];
  assert.ok(staging, "pre-credential staging step must exist");
  assert.match(staging, /AWESOMUX_SPARKLE_ENABLED=1/);
  assert.match(staging, /\.\/script\/build_and_run\.sh --stage-release/);

  const afterImport = workflow.slice(workflow.indexOf("- name: Import signing identity"));
  assert.doesNotMatch(afterImport, /build_and_run\.sh|swift build|ensure_ghostty_artifacts\.sh/);
});

test("release credentials are removed before third-party publication steps", () => {
  const verification = workflow.indexOf("- name: Verify release outputs before publication");
  const cleanup = workflow.indexOf("- name: Remove signing credentials before publication");
  const upload = workflow.indexOf("- name: Upload release DMG");

  assert.ok(verification >= 0 && cleanup > verification && upload > cleanup);
  const cleanupStep = workflow.slice(cleanup, upload);
  assert.match(cleanupStep, /security delete-keychain "\$KEYCHAIN_PATH"/);
  assert.match(cleanupStep, /rm -f "\$P12_PATH" "\$NOTARY_KEY_PATH"/);
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
  assert.match(generation, /\.build\/artifacts\/sparkle\/Sparkle\/bin\/sign_update/);
  assert.match(generation, /\[\[ -x "\$APPCAST_TOOL" \]\]/);
  assert.match(generation, /printf '%s' "\$SPARKLE_PRIVATE_ED_KEY" \|/);
  assert.match(generation, /--ed-key-file -/);
  assert.match(generation, /--maximum-deltas 0/);
  assert.match(generation, /--download-url-prefix "https:\/\/github\.com\/Interactive-Buffoonery\/awesomux\/releases\/download\/v\$RELEASE_VERSION\/"/);
  assert.match(generation, /-o "\$GITHUB_WORKSPACE\/appcast\.xml"/);
  assert.match(generation, /dist\/release\/awesoMux-\$RELEASE_VERSION\.dmg/);
  assert.match(generation, /EXPECTED_DMG_URL="https:\/\/github\.com\/Interactive-Buffoonery\/awesomux\/releases\/download\/v\$RELEASE_VERSION\/awesoMux-\$RELEASE_VERSION\.dmg"/);
  assert.match(generation, /"\$GITHUB_WORKSPACE\/\.github\/scripts\/validate_appcast\.sh" "\$GITHUB_WORKSPACE\/appcast\.xml" "\$EXPECTED_DMG_URL"/);
  assert.match(generation, /printf '%s' "\$SPARKLE_PRIVATE_ED_KEY" \| "\$SIGN_UPDATE_TOOL" --verify --ed-key-file - "\$GITHUB_WORKSPACE\/appcast\.xml"/);
  assert.doesNotMatch(generation, /generate_keys|echo "\$SPARKLE_PRIVATE_ED_KEY"|>[^|\n]*SPARKLE_PRIVATE_ED_KEY/);

  const earlyValidation = workflow.match(
    /\n      - name: Verify appcast signing secret is present[\s\S]*?(?=\n      - name: Resolve release collisions)/,
  )?.[0];
  assert.ok(earlyValidation, "early appcast key validation step must exist");
  const outsideKeySteps = workflow.replace(generation, "").replace(earlyValidation, "");
  assert.doesNotMatch(outsideKeySteps, /SPARKLE_PRIVATE_ED_KEY/);

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

test("appcast validator accepts one signed enclosure at the expected URL", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
  `, validFeedSignature);

  assert.equal(result.status, 0, result.stderr);
});

test("appcast validator rejects a missing feed signature trailer", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
  `, "");

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /signed feed trailer/);
});

test("appcast validator rejects an empty feed signature", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
  `, "<!-- sparkle-signatures:\nedSignature: \nlength: 123\n-->");

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /signed feed trailer/);
});

test("appcast validator rejects a non-positive feed signature length", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
  `, "<!-- sparkle-signatures:\nedSignature: ZmVlZC1zaWduYXR1cmU=\nlength: 0\n-->");

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /signed feed trailer/);
});

test("appcast validator rejects an unexpected enclosure URL", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="https://example.invalid/awesoMux-9.9.9.dmg" sparkle:edSignature="signed-value" />
  `);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unexpected enclosure URL/);
});

test("appcast validator rejects an empty Sparkle EdDSA signature", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="" />
  `);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /nonempty sparkle:edSignature/);
});

test("appcast validator rejects multiple enclosures", { skip: !canValidateAppcast }, () => {
  const result = validateFixture(`
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
    <enclosure url="${expectedDmgURL}" sparkle:edSignature="signed-value" />
  `);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /exactly one enclosure/);
});

const validFeedSignature = "<!-- sparkle-signatures:\nedSignature: ZmVlZC1zaWduYXR1cmU=\nlength: 123\n-->";

function validateFixture(enclosures, feedSignature = validFeedSignature) {
  assert.ok(existsSync(appcastValidator), "appcast validator must exist");
  const fixtureRoot = mkdtempSync(join(tmpdir(), "awesomux-appcast-validation-"));
  const appcastPath = join(fixtureRoot, "appcast.xml");
  try {
    writeFileSync(appcastPath, `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item>${enclosures}</item></channel>
</rss>
${feedSignature}
`);
    return spawnSync("bash", [appcastValidator, appcastPath, expectedDmgURL], { encoding: "utf8" });
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}
