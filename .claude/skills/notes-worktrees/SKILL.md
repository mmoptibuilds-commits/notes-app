---
name: notes-worktrees
description: Set up or coordinate isolated Git worktrees for parallel Notes tasks and reviews.
---

1. Claim the task in its shared ticket or handover before editing. Record the owner, branch, base SHA and paths in scope. Agree on ownership of shared files before another task edits them.
2. Inspect `git status --short --branch`, `git worktree list` and the intended base. For a new branch, use `git worktree add -b <branch> <path> <base-sha>`. For a handover, first find the existing worktree and confirm ownership has transferred.
3. Open the agent at that worktree's root. Keep builds, synthetic data and dev sessions isolated. Use a unique `NOTES_DATA_DIR` outside the repo for native runs. Coordinate exclusive use of any shared emulator or test Worker.
4. Preserve dirty checkouts and local commits. Hand off a named branch and exact SHA. Review in a separate worktree at that SHA. Follow [agent tooling](../../../docs/AGENT_TOOLING.md) and the approval rules in `AGENTS.md`.
