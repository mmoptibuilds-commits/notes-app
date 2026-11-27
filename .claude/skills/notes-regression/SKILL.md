---
name: notes-regression
description: Reproduce Notes defects, choose targeted regression coverage, and run independent verification.
---

1. Record the failing command, environment and base SHA. Reproduce on the unchanged base with synthetic data. For a fix, run the same check on the candidate and show that it passes.
2. Use the nearest test layer and the existing helpers in `test/support/`. Run targeted tests first, then the applicable gates in [Development](../../../docs/DEVELOPMENT.md). For Worker changes, run locked install, typecheck, tests and build.
3. Keep known failures visible. Record failing test names, output and affected environments against the base. Tag opt-in checks as skipped when their test environment is absent.
4. For handover or merge review, verify the exact committed SHA in a clean worktree. Record commands and observed results in the task record.
