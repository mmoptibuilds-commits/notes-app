#!/usr/bin/env python3
"""Generate or check the regular-file Claude Code mirrors of Notes skills."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SKILLS = {
    "notes-data-integrity",
    "notes-handoff",
    "notes-regression",
    "notes-release",
    "notes-ui-qa",
    "notes-worktrees",
}
FRONTMATTER = re.compile(r"\A---\nname: ([a-z0-9-]+)\ndescription: (\S[^\n]*)\n---\n")


def skill_paths(parent: str, *, allow_missing: bool = False) -> dict[str, Path]:
    directory = ROOT / parent / "skills"
    for path in (directory.parent, directory):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError(f"Expected a real directory: {path.relative_to(ROOT)}")

    existing = {path.name for path in directory.iterdir()} if directory.exists() else set()
    extra = existing - SKILLS
    missing = SKILLS - existing
    if extra or (missing and not allow_missing):
        raise ValueError(
            f"{directory.relative_to(ROOT)}: unexpected {sorted(extra)}, missing {sorted(missing)}"
        )

    paths = {}
    for name in sorted(SKILLS):
        folder = directory / name
        skill = folder / "SKILL.md"
        if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
            raise ValueError(f"Expected a real directory: {folder.relative_to(ROOT)}")
        if folder.exists() and any(path != skill for path in folder.iterdir()):
            raise ValueError(f"Expected only SKILL.md in {folder.relative_to(ROOT)}")
        if skill.is_symlink() or (
            not skill.is_file() and (skill.exists() or not allow_missing)
        ):
            raise ValueError(f"Expected a regular file: {skill.relative_to(ROOT)}")
        paths[name] = skill
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "check"))
    args = parser.parse_args()
    generate = args.command == "generate"

    try:
        sources = skill_paths(".agents")
        mirrors = skill_paths(".claude", allow_missing=generate)
        contents = {}
        for name, path in sources.items():
            content = path.read_bytes()
            header = FRONTMATTER.match(content.decode("utf-8"))
            if (
                not header
                or header[1] != name
                or len(header[2]) > 1024
                or not content[header.end():].strip()
                or b"\r" in content
            ):
                raise ValueError(f"Invalid skill format: {path.relative_to(ROOT)}")
            contents[name] = content

        drift = []
        for name, path in mirrors.items():
            if path.is_file() and path.read_bytes() == contents[name]:
                continue
            if generate:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents[name])
            else:
                drift.append(str(path.relative_to(ROOT)))
        if drift:
            raise ValueError(
                f"Mirror differs: {', '.join(drift)}. "
                "Run python3 tool/sync_agent_skills.py generate."
            )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    print(f"{len(SKILLS)} Notes skill mirrors {'generated' if generate else 'verified'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
