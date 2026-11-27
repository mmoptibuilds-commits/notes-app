# Task handover

Keep one authoritative handover in the task issue or in the task branch at `docs/handovers/<task-id>.md`. Update it when handing off, pausing or requesting review. Reference it from the backlog when it is the primary task record. A new session should be able to start from this record and the checkout.

```markdown
# <task ID and outcome>
- Status and active owner
- Branch, worktree path, base SHA and checkpoint SHA
- Remote checkpoint or local-only changes and their paths
- Scope and acceptance checks
- Completed work and decisions
- Verification per command, SHA, environment and exit status
- Baseline failures, skipped checks and blockers
- Next action and reviewer, if assigned
```

Commit in-scope changes before transferring work where possible. Record the code checkpoint SHA before the handover-only commit if the handover is in the branch. Include any dirty paths and why they are local. Use sanitized logs and keep private material out of the record.

To resume, confirm ownership, locate the checkout with `git worktree list`, verify the recorded SHA and compare the diff with the base. Run the most relevant check before editing. A separate reviewer records verification against the exact candidate SHA.
