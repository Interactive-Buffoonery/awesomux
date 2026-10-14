#!/usr/bin/env python3
"""Install reviewed local skill files and optionally save nonsecret connection setup."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import uuid


FILES = ("SKILL.md", "references/helper.md")
KEYS = {"schemaVersion", "helperPath", "profile", "connectionID"}


def safe_path(path, directory=False):
    for entry in (*reversed(path.parents), path):
        if entry.is_symlink():
            raise ValueError(f"Symlink destination refused: {entry}")
        if entry.exists():
            if entry != path or directory:
                if not entry.is_dir():
                    raise ValueError(f"Expected directory: {entry}")
            elif not entry.is_file():
                raise ValueError(f"Expected regular file: {entry}")
    if path.exists() and path.stat().st_uid != os.geteuid():
        raise ValueError(f"Destination is not owned by this user: {path}")


def validate_setup(value, check_helper=True):
    if not isinstance(value, dict) or set(value) != KEYS or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("Connection config must contain exactly schemaVersion=1, helperPath, profile, connectionID")
    if not all(isinstance(value[key], str) for key in KEYS - {"schemaVersion"}):
        raise ValueError("Connection setup values must be strings")
    helper = Path(value["helperPath"])
    if not helper.is_absolute() or (check_helper and (not helper.is_file() or not os.access(helper, os.X_OK))):
        raise ValueError("Helper path must be an absolute executable file")
    if not re.fullmatch(r"production|development(?::[0-9a-f]{12})?", value["profile"]):
        raise ValueError("Profile must be production, development, or development:<12 lowercase hex digits>")
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value["connectionID"]):
        raise ValueError("Connection ID must be a hyphenated UUID")
    uuid.UUID(value["connectionID"])
    return value


def write_file(path, payload, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    previous = path.read_bytes() if path.exists() else None
    if previous == payload:
        return
    if previous is not None:
        backup = path.with_name(f"{path.name}.backup-{uuid.uuid4().hex}")
        backup_mode = stat.S_IMODE(path.stat().st_mode) & mode
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, backup_mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(previous)
        print(f"Backed up {path} to {backup}")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"Updated {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper-path")
    parser.add_argument("--profile")
    parser.add_argument("--connection-id")
    parser.add_argument("--replace-connection", action="store_true",
                        help="Explicitly replace different saved setup after reviewing the new values")
    args = parser.parse_args()
    supplied = (args.helper_path, args.profile, args.connection_id)
    if any(value is not None for value in supplied) and not all(value is not None for value in supplied):
        parser.error("Supply --helper-path, --profile and --connection-id together, or none")
    if args.replace_connection and not all(value is not None for value in supplied):
        parser.error("--replace-connection requires all three setup values")
    root = Path(__file__).resolve().parent.parent
    source = root / "Resources/AgentIntegrations/openai/skills/awesomux-read-only"
    destination = Path.home() / ".agents/skills/awesomux-read-only"
    config = Path.home() / ".config/awesomux/read-only-connection.json"
    try:
        setup = None
        if args.helper_path is not None:
            setup = validate_setup(dict(schemaVersion=1, helperPath=args.helper_path,
                                        profile=args.profile, connectionID=args.connection_id))
            safe_path(config)
            if config.exists():
                if stat.S_IMODE(config.stat().st_mode) != 0o600:
                    raise ValueError("Existing connection config must have mode 0600")
                try:
                    previous = validate_setup(json.loads(config.read_text()), check_helper=False)
                except ValueError as error:
                    raise ValueError(f"{error}. Preserve the existing config by moving it aside, then rerun reviewed setup") from error
                if previous != setup and not args.replace_connection:
                    raise ValueError("Saved setup differs; review values and use --replace-connection to replace it")
        safe_path(destination, directory=True)
        payloads = []
        for name in FILES:
            resource = source / name
            if any(entry.is_symlink() for entry in (resource, *resource.parents) if entry != root and root in entry.parents):
                raise ValueError(f"Symlinked skill resource refused: {name}")
            if not resource.is_file():
                raise ValueError(f"Missing skill resource: {name}")
            target = destination / name
            safe_path(target)
            payloads.append((target, resource.read_bytes()))
        for target, payload in payloads:
            write_file(target, payload, 0o644)
        if setup is not None:
            write_file(config, (json.dumps(setup, indent=2) + "\n").encode(), 0o600)
        print(f"Installed skill: {destination}")
        print("Start a new local task and verify skill discovery; catalog links were not changed.")
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
