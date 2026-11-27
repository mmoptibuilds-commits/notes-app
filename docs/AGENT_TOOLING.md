# Agent tooling

Open each agent at its worktree root. [AGENTS.md](../AGENTS.md) is the project rulebook.

## Parallel tasks

1. The coordinator assigns one active owner per task and records the target branch, base SHA, write scope and acceptance checks in its issue or branch handover. Coordinate overlapping paths before either task starts. Track approved release scope in the [roadmap](ROADMAP.md) and task state in the [backlog](BACKLOG.md).
2. Run `git worktree list` and `git status --short --branch`. Create a task worktree with `git worktree add -b <branch> <path> <base-sha>`. Use a unique branch, directory and `NOTES_DATA_DIR` for each task. Keep real data, signing configuration and cloud sessions out of worktrees. Reserve shared emulators and the test Worker with the coordinator before running tests that alter them.
3. Keep the task record current. Before switching owners, record the exact checkpoint and next action using the [handover template](HANDOVER.md). Preserve existing dirty worktrees. A committed and authorized pushed checkpoint lets another machine resume.
4. Ask a separate reviewer to inspect the diff and rerun the relevant checks in a detached worktree at the exact candidate SHA. Record their commands and results. Reverify a changed candidate before merging. Follow the owner approval rules in [AGENTS.md](../AGENTS.md).

## Skills and harnesses

Each canonical skill is a small `.agents/skills/<name>/SKILL.md`. Generate and commit the byte-identical regular files under `.claude/skills/` with `python3 tool/sync_agent_skills.py generate`. CI runs `python3 tool/sync_agent_skills.py check`. Keep both directories limited to the six project skills. Resolve links in skill bodies from the skill directory.

| Harness | Project rules | Skill discovery |
|---|---|---|
| Codex | `AGENTS.md` | `.agents/skills/`. Inspect the skill picker or call `skills/list` with the worktree as its cwd. [Rules](https://learn.chatgpt.com/docs/agent-configuration/agents-md) · [Skills](https://learn.chatgpt.com/docs/build-skills) |
| Claude Code | `CLAUDE.md` imports `AGENTS.md` | `.claude/skills/`. Inspect `/skills` and use `/context all` for memory files. [Rules](https://code.claude.com/docs/en/memory) · [Skills](https://code.claude.com/docs/en/skills) |
| Google Antigravity | `AGENTS.md` | `.agents/skills/`. Use CLI `/skills` or the app's Installed customizations panel. [Discovery](https://antigravity.google/docs/customization-discovery/) |
| OpenCode | `AGENTS.md` | Both skill directories. The canonical copy takes precedence over the Claude copy for the same ID. [Rules](https://opencode.ai/docs/instructions/) · [Skills](https://opencode.ai/docs/skills/) |

Graphify is an [optional local navigation aid](GRAPHIFY.md). External skills are [on-demand references](EXTERNAL_SKILLS.md). Neither is required by CI or the native app.
