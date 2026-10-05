#!/usr/bin/env python3
"""Exercise the packaging CLI and preserve a repeatable artifact report."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


def main():
    root = Path(__file__).resolve().parent.parent
    artifact = Path(sys.argv[1]) if len(sys.argv) == 2 else root / ".build/dot-skill-e2e"
    artifact.mkdir(parents=True, exist_ok=True)
    checks = []

    def check(condition, name):
        if not condition:
            raise RuntimeError(name)
        checks.append(name)
        print(f"PASS: {name}")

    def run(script, output):
        return subprocess.run([sys.executable, str(script), str(output)], capture_output=True, timeout=10)

    with tempfile.TemporaryDirectory(prefix="awesomux-dot-package-") as temporary:
        work = Path(temporary)
        script = root / "script/package-dot-skill.py"
        first = work / "first.zip"
        second = work / "second.zip"
        check(run(script, first).returncode == 0, "package CLI creates archive")
        check(run(script, second).returncode == 0, "second package succeeds")
        content = first.read_bytes()
        check(content == second.read_bytes(), "archives are byte-for-byte reproducible")
        with zipfile.ZipFile(first) as archive:
            names = archive.namelist()
            check(names == ["awesomux-read-only/SKILL.md", "awesomux-read-only/references/helper.md"],
                  "archive contains only the self-contained skill resources")
            check(all(not name.startswith("/") and ".." not in Path(name).parts for name in names),
                  "archive entries stay within one skill folder")
            for name in names:
                source = root / "Resources/AgentIntegrations/openai/skills" / name
                check(archive.read(name) == source.read_bytes(), f"packaged {name} matches source")
            extracted = work / "extracted"
            archive.extractall(extracted)
        check((extracted / "awesomux-read-only/references/helper.md").is_file(),
              "extracted reference is available beside the skill")
        check(run(script, first).returncode != 0 and first.read_bytes() == content,
              "existing archive is refused and unchanged")
        check(run(script, work / "wrong.txt").returncode != 0 and not (work / "wrong.txt").exists(),
              "invalid output extension creates nothing")
        fixture = work / "fixture"
        (fixture / "script").mkdir(parents=True)
        fixture_script = fixture / "script/package-dot-skill.py"
        shutil.copyfile(script, fixture_script)
        missing = work / "missing.zip"
        check(run(fixture_script, missing).returncode != 0 and not missing.exists(),
              "missing resources fail before output creation")
        skill = fixture / "Resources/AgentIntegrations/openai/skills/awesomux-read-only"
        (skill / "references").mkdir(parents=True)
        shutil.copyfile(root / "Resources/AgentIntegrations/openai/skills/awesomux-read-only/references/helper.md",
                        skill / "references/helper.md")
        (skill / "SKILL.md").symlink_to(root / "Resources/AgentIntegrations/openai/skills/awesomux-read-only/SKILL.md")
        refused = work / "symlink.zip"
        symlink_result = run(fixture_script, refused)
        check(symlink_result.returncode != 0 and b"must not be a symlink" in symlink_result.stderr and not refused.exists(),
              "symlinked resource fails before output creation")
        shutil.copyfile(first, artifact / "awesomux-read-only.zip")
    report = {
        "scope": "packaging CLI; no Dot, phone, native UI, or real-agent acceptance",
        "checks": checks,
        "archiveSHA256": hashlib.sha256(content).hexdigest(),
    }
    (artifact / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {artifact / 'report.json'}")


if __name__ == "__main__":
    main()
