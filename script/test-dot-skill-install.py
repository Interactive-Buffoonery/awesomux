#!/usr/bin/env python3
"""Exercise local installation through the CLI in disposable home directories.

Failure matrix (written before the installer): incomplete or invalid setup,
missing/nonexecutable helper, unsafe source/destination symlinks, foreign files,
malformed/extra-key config, existing installation updates, preserved unrelated
files, backup collisions, accidental credentials, and implicit connection changes.
Each invocation uses a fixture HOME; it never calls the helper or Keychain.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    artifact = Path(sys.argv[1]) if len(sys.argv) == 2 else root / ".build/dot-skill-install-e2e"
    artifact.mkdir(parents=True, exist_ok=True)
    checks = []
    calls = []
    installer = root / "script/install-dot-skill.py"
    connection = "01234567-89ab-cdef-0123-456789abcdef"

    def check(condition, name):
        if not condition:
            raise RuntimeError(name)
        checks.append(name)
        print(f"PASS: {name}")

    with tempfile.TemporaryDirectory(prefix="awesomux-dot-install-") as temporary:
        work = Path(temporary).resolve()
        helper = work / "helper with spaces"
        helper.write_text("#!/bin/sh\nexit 99\n")
        helper.chmod(0o700)
        setup = ["--helper-path", str(helper), "--profile", "development:012345abcdef",
                 "--connection-id", connection]

        def run(home, *args):
            home.mkdir(exist_ok=True)
            result = subprocess.run([sys.executable, "-B", str(installer), *args],
                                    env={**os.environ, "HOME": str(home)}, capture_output=True,
                                    text=True, timeout=10)
            calls.append({"arguments": list(args), "exitCode": result.returncode,
                          "stdout": result.stdout, "stderr": result.stderr})
            return result

        home = work / "home"
        skill = home / ".agents/skills/awesomux-read-only"
        config = home / ".config/awesomux/read-only-connection.json"
        check(run(home, *setup).returncode == 0, "install and save reviewed setup")
        for name in ("SKILL.md", "references/helper.md"):
            check((skill / name).read_bytes() == (root / "Resources/AgentIntegrations/openai/skills/awesomux-read-only" / name).read_bytes(),
                  f"installed {name} matches source")
        expected = dict(schemaVersion=1, helperPath=str(helper), profile="development:012345abcdef", connectionID=connection)
        check(json.loads(config.read_text()) == expected, "config contains only schema and nonsecret setup")
        check(config.stat().st_mode & 0o777 == 0o600, "config has owner-only permissions")
        before = config.read_bytes()
        check(run(home).returncode == 0 and config.read_bytes() == before,
              "update without setup preserves saved connection")
        check(not list(skill.rglob("*.backup-*")), "identical install needs no backups")
        (skill / "SKILL.md").write_text("older reviewed skill\n")
        unrelated = skill / "personal-notes.md"
        unrelated.write_text("preserve me")
        check(run(home).returncode == 0 and unrelated.read_text() == "preserve me",
              "update preserves unrelated installed files")
        backups = list(skill.glob("SKILL.md.backup-*"))
        check(len(backups) == 1 and backups[0].read_text() == "older reviewed skill\n",
              "changed owned resource is backed up")
        private_home = work / "private-skill"
        check(run(private_home).returncode == 0, "private backup fixture installs")
        private_skill = private_home / ".agents/skills/awesomux-read-only/SKILL.md"
        private_skill.write_text("private reviewed skill\n")
        private_skill.chmod(0o600)
        private_update = run(private_home)
        private_backups = list(private_skill.parent.glob("SKILL.md.backup-*"))
        check(private_update.returncode == 0 and len(private_backups) == 1 and
              private_backups[0].stat().st_mode & 0o777 == 0o600,
              "backup preserves private file permissions")
        check(run(home, *setup).returncode == 0 and config.read_bytes() == before,
              "explicit identical config reuses connection")
        changed = setup[:-1] + ["abcdef01-2345-6789-abcd-ef0123456789"]
        check(run(home, *changed).returncode != 0 and config.read_bytes() == before,
              "different connection requires explicit replacement")
        check(run(home, *changed, "--replace-connection").returncode == 0 and
              json.loads(config.read_text())["connectionID"] == changed[-1] and
              any(p.read_bytes() == before for p in config.parent.glob("*.backup-*")),
              "explicit connection replacement retains previous config backup")
        stale_home = work / "stale-home"
        stale_helper = work / "old-helper"
        stale_helper.write_text("#!/bin/sh\nexit 99\n")
        stale_helper.chmod(0o700)
        old_setup = ["--helper-path", str(stale_helper), *setup[2:]]
        check(run(stale_home, *old_setup).returncode == 0, "stale helper fixture installs")
        stale_helper.rename(work / "old-helper-moved-aside")
        check(run(stale_home, *setup, "--replace-connection").returncode == 0,
              "reviewed replacement repairs stale helper setup")
        invalids = [setup[:2], setup[:-1], ["--helper-path", "relative", *setup[2:]],
                    [*setup[:3], "development:BAD", *setup[4:]],
                    [*setup[:-1], "not-a-uuid"], ["--helper-path", str(work / "missing"), *setup[2:]]]
        for number, values in enumerate(invalids):
            invalid_home = work / f"invalid-{number}"
            check(run(invalid_home, *values).returncode != 0 and not (invalid_home / ".agents").exists(),
                  f"invalid or incomplete setup {number} refuses before installation")
        source_fixture = work / "source-fixture"
        (source_fixture / "script").mkdir(parents=True)
        fixture_installer = source_fixture / "script/install-dot-skill.py"
        shutil.copyfile(installer, fixture_installer)
        actual_installer = installer
        installer = fixture_installer
        missing_home = work / "missing-source"
        check(run(missing_home, *setup).returncode != 0 and not (missing_home / ".agents").exists(),
              "missing source refuses before any destination writes")
        resources = source_fixture / "Resources/AgentIntegrations/openai/skills/awesomux-read-only"
        (resources / "references").mkdir(parents=True)
        (resources / "SKILL.md").symlink_to(skill / "SKILL.md")
        shutil.copyfile(skill / "references/helper.md", resources / "references/helper.md")
        check(run(missing_home, *setup).returncode != 0 and not (missing_home / ".agents").exists(),
              "symlink source refuses before any destination writes")
        installer = actual_installer
        (skill / "SKILL.md").write_text("preserve before prevalidation")
        (skill / "references/helper.md").rename(skill / "references/previous-helper.md")
        (skill / "references/helper.md").symlink_to(skill / "references/previous-helper.md")
        check(run(home).returncode != 0 and (skill / "SKILL.md").read_text() == "preserve before prevalidation",
              "unsafe second destination refuses before changing first resource")
        (skill / "references/helper.md").unlink()
        (skill / "references/previous-helper.md").rename(skill / "references/helper.md")
        helper.chmod(0o600)
        check(run(work / "nonexecutable", *setup).returncode != 0,
              "nonexecutable helper is refused")
        helper.chmod(0o700)
        unsafe = work / "unsafe"
        unsafe.mkdir()
        (unsafe / ".agents").symlink_to(home / ".agents")
        check(run(unsafe).returncode != 0, "symlinked installation ancestor is refused")
        (skill / "SKILL.md").unlink()
        (skill / "SKILL.md").symlink_to(unrelated)
        check(run(home).returncode != 0 and unrelated.read_text() == "preserve me",
              "symlinked owned file is refused without touching target")
        (skill / "SKILL.md").unlink()
        (skill / "SKILL.md").mkdir()
        check(run(home).returncode != 0, "directory at owned file is refused")
        clean = work / "config-invalid"
        check(run(clean, *setup).returncode == 0, "config refusal fixture installs")
        bad = clean / ".config/awesomux/read-only-connection.json"
        for content in ("{broken", json.dumps({**expected, "credential": "DO NOT OVERWRITE"})):
            bad.write_text(content)
            check(run(clean, *setup).returncode != 0 and bad.read_text() == content,
                  "malformed or unexpected config is preserved and refused")
        check(run(clean).returncode == 0 and bad.read_text() == content,
              "skill-only update never rewrites malformed saved config")
        bad.write_text(json.dumps(expected))
        bad.chmod(0o644)
        check(run(clean, *setup).returncode != 0 and bad.stat().st_mode & 0o777 == 0o644,
              "insecure existing config is refused unchanged")
        bad.chmod(0o600)
        for profile in ("production", "development"):
            check(run(work / f"profile-{profile}", *setup[:3], profile, *setup[4:]).returncode == 0,
                  f"exact {profile} profile accepted")
        bad.unlink()
        bad.symlink_to(config)
        check(run(clean, *setup).returncode != 0 and json.loads(config.read_text())["connectionID"] == changed[-1],
              "symlinked config is refused without touching target")
        report = {"scope": "installer CLI fixtures; no helper, Keychain, Dot or phone delivery",
                  "checks": checks, "calls": calls}
        (artifact / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {artifact / 'report.json'}")


if __name__ == "__main__":
    main()
