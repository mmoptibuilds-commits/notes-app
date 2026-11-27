---
name: notes-data-integrity
description: Protect Notes data when changing persistence, migrations, import, sync or editor saves.
---

1. Read the affected data flow in [Architecture](../../../docs/ARCHITECTURE.md). Identify mutation callers, transaction boundaries, sync metadata, and retry or interruption behaviour.
2. Route note mutations through `NoteRepository` and keep each multi-row write atomic. Append migrations and test upgrading from the released schema. Check protocol compatibility with installed peers before changing wire data.
3. Cover relevant rollback, replay or conflict cases with synthetic fixtures, including persistence after reopening. Opening notes and first-run onboarding must preserve the library. Verify editor saves survive app or updater transitions when affected.
4. Use a temporary data directory and local fixtures. Live checks may use only the isolated test Worker. Keep data and credentials out of test output and handovers.
