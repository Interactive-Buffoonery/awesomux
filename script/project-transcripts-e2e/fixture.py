#!/usr/bin/env python3
"""Create synthetic provider logs for coordinator-owned native acceptance."""
import json
import pathlib
import sys


def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=False)
    project = root / "project-a"
    other = root / "project-b"
    project.mkdir()
    other.mkdir()
    claude = root / "claude"
    codex = root / "codex"
    ids = [f"10000000-0000-4000-8000-{number:012d}" for number in range(1, 11)]

    def write(path, records):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(record) + "\n" for record in records))

    slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(project))
    parent_path = claude / "projects" / slug / f"{ids[0]}.jsonl"
    write(parent_path, [
        {"type": "user", "sessionId": ids[0], "cwd": str(project),
         "message": {"role": "user", "content": "CLAUDE_PROJECT_A"}},
        {"type": "assistant", "sessionId": ids[8], "cwd": str(other),
         "isSidechain": True, "message": {"content": "INLINE_CHILD_METADATA_IGNORED"}},
    ])
    write(claude / "projects" / slug / f"{ids[8]}.jsonl", [
        {"type": "user", "sessionId": ids[8], "cwd": str(project),
         "isSidechain": True, "message": {"content": "CLAUDE_CHILD_HIDDEN"}},
    ])

    write(claude / "projects" / slug / f"{ids[7]}.jsonl", [
        {"type": "user", "sessionId": ids[7], "cwd": str(other),
         "message": {"content": "WRONG_PROJECT_IN_MATCHING_SLUG_HIDDEN"}},
    ])
    (claude / "projects" / slug / "enumerated-directory-alias").symlink_to(
        claude / "projects" / slug, target_is_directory=True)
    configured_home_alias = root / "claude-home-alias"
    configured_home_alias.symlink_to(claude, target_is_directory=True)

    other_slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(other))
    write(claude / "projects" / other_slug / f"{ids[0]}.jsonl", [
        {"type": "user", "sessionId": ids[0], "cwd": str(other),
         "message": {"content": "CLAUDE_PROJECT_B_DUPLICATE " * 200}},
    ])
    alias_home = root / "claude-intermediate-alias"
    alias_home.mkdir()
    (alias_home / "projects").symlink_to(claude / "projects", target_is_directory=True)

    def rollout(number, cwd, marker=None, **extra):
        meta = {"id": ids[number], "session_id": "shared-family", "cwd": str(cwd),
                "source": "cli", **extra}
        rows = [{"type": "session_meta", "payload": meta}]
        if marker:
            rows.append({"type": "response_item", "payload": {
                "type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": marker}]}})
        return rows

    base = codex / "sessions" / "2026" / "10" / "17"
    for number, rows in [
        (1, rollout(1, project, "DUPLICATE_CONVERSATION_WINS")),
        (2, rollout(2, project, "FAMILY_MEMBER_ONE")),
        (3, rollout(3, project, "FAMILY_MEMBER_TWO")),
        (4, rollout(4, other, "OTHER_PROJECT_HIDDEN")),
        (5, rollout(5, project, "CHILD_SOURCE_HIDDEN", source={"subagent": {}})),
        (6, rollout(6, project, "CHILD_PARENT_HIDDEN", parent_thread_id=ids[1])),
    ]:
        write(base / f"rollout-2026-10-17-{ids[number]}.jsonl", rows)
    write(base / f"rollout-other-project-{ids[1]}.jsonl",
          rollout(1, other, "PROJECT_B_DUPLICATE_MUST_NOT_REPLACE_A " * 200))
    history = rollout(9, project)
    history.append({"type": "response_item", "payload": {
        "type": "message", "role": "developer", "content": "SETUP " * 60000}})
    history.extend(rollout(9, project, "LARGE_FIRST_RECORD_HISTORY_WINS")[1:])
    write(base / f"rollout-large-first-record-{ids[9]}.jsonl", history)
    setup = rollout(9, project)
    for role in ["system", "developer"]:
        setup.append({"type": "response_item", "payload": {
            "type": "message", "role": role, "content": "SETUP_ONLY_MUST_LOSE"}})
    setup.extend([
        {"type": "response_item", "payload": {"type": "unsupported", "content": "NOT_HISTORY"}},
        {"type": "event_msg", "payload": {"type": "agent_message", "message": "NOT_HISTORY"}},
        {"type": "response_item", "payload": {"type": "message", "role": "user",
         "content": [{"type": "input_text", "text": "HARNESS_ONLY"}],
         "internal_chat_message_metadata_passthrough": {
             "content_item_kinds": ["agents_md.instructions"]}}},
    ])
    write(base / f"rollout-setup-sidecar-{ids[9]}.jsonl", setup)
    write(base / f"rollout-sidecar-{ids[1]}.jsonl", rollout(1, project))
    (base / f"rollout-symlink-{ids[7]}.jsonl").symlink_to(
        base / f"rollout-2026-10-17-{ids[1]}.jsonl")
    write(base / "rollout-incomplete.jsonl", [{"padding": "x" * 65536}])
    manifest = {"project": str(project), "other_project": str(other),
                "claude_config_home": str(claude), "codex_config_home": str(codex),
                "claude_intermediate_alias_home": str(alias_home),
                "claude_configured_home_alias": str(configured_home_alias),
                "expected_project_a_ids": ids[:4] + [ids[9]],
                "expected_project_b_ids": [ids[0], ids[1], ids[4]],
                "mixed_parent_source": str(parent_path),
                "large_first_record_id": ids[9]}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
