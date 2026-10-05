#!/usr/bin/env python3
"""Package the local read-only skill without installing or configuring access."""

import argparse
from pathlib import Path
import stat
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New ZIP archive; existing files are refused")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    skill = root / "Resources/AgentIntegrations/openai/skills/awesomux-read-only"
    files = ("SKILL.md", "references/helper.md")
    payloads = []
    for name in files:
        path = skill / name
        if any(parent.is_symlink() for parent in (path, *path.parents) if parent != root and root in parent.parents):
            parser.error(f"Skill resource must not be a symlink: {name}")
        if not path.is_file():
            parser.error(f"Missing skill resource: {name}")
        payloads.append((name, path.read_bytes()))
    if args.output.suffix != ".zip":
        parser.error("Output must have a .zip extension")
    try:
        with zipfile.ZipFile(args.output, "x", compression=zipfile.ZIP_STORED) as archive:
            for name, content in payloads:
                entry = zipfile.ZipInfo(f"awesomux-read-only/{name}", date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(entry, content)
    except OSError as error:
        parser.error(str(error))
    print(args.output)


if __name__ == "__main__":
    main()
