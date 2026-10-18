import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
const appcastValidator = fileURLToPath(new URL("../validate_appcast.sh", import.meta.url));
const expectedDmgURL = "https://github.com/Interactive-Buffoonery/awesomux/releases/download/v9.9.9/awesoMux-9.9.9.dmg";
const canValidateAppcast = existsSync("/usr/bin/xmllint");

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
