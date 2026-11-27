# Notes roadmap

Status: the owner approved v1.3.2 implementation on 2026-11-28; that candidate is active. Later releases remain proposed. Current stable: v1.3.1 (build 20261127). Tooling is merged in [PR #8](https://github.com/mmoptibuilds-commits/notes-app/pull/8). This roadmap does not authorize work on later releases.

Read [REQUIREMENTS.md](REQUIREMENTS.md) for accepted product decisions, [BACKLOG.md](BACKLOG.md) for the complete inventory, and [plans/v1.3.2.md](plans/v1.3.2.md) for the approved application patch. Existing [PRODUCT.md](PRODUCT.md) describes current behavior; future decisions do not retroactively change shipped behavior.

## Release sequence

Target: a safe v2.0 milestone before December 31, 2026, if all gates pass. Dates are aspirational, not promises. Split or defer unfinished scope rather than weaken data safety.

| Release | Candidate window | Purpose and dependencies | Exit gate |
| --- | --- | --- | --- |
| Preparation | Complete | Six skills, four harnesses, isolated worktrees, CI, documentation | PR #8 merged; main CI passed |
| 1.3.2 | Nov 29–Dec 1 | Data integrity: Linux sequence allocation, recovery backups, draft persistence, updater and quarantine safeguards | Crash/recovery, encrypted migration, relevant updater and regression checks |
| 1.3.3 | Dec 1–4 | Cloud reliability after 1.3.2: pagination, blob downloads, initial upload, request sizing, legacy IDs, retries, relink and safe cleanup | Isolated backend convergence and interruption tests; no silent skipped edits |
| 1.4.0 | Dec 4–7 | Editor reliability after safe saves and sync: selection/keyboard, formatting, Undo/Redo, code, find/replace, Markdown shortcuts, bounded history | Mouse, keyboard, touch, reopen and sync regression tests |
| 1.5.0 | Dec 7–11 | Everyday UX: desktop controls, organization, templates, links, details, Android toolbar, themes/backgrounds, change log | Responsive, accessibility, keyboard and performance checks |
| 1.6.0 | Dec 11–16 | Open-note updates, concurrent editing, presence, offline merge and recovery; LAN removal only after cloud parity | Prototype proves convergence, replay, old-peer handling and free-tier budget |
| 1.7.0 | Dec 16–21 | Isolated workspaces, scoped agent identity, shared API, CLI/MCP, chat and queued mentions | Cross-workspace denial tests for all paths, including old clients and attachments |
| 1.8.0 | Dec 21–25 | iPhone online-first web, Windows native and then responsive iPad web; reuse workspace-aware API/editor | Real Safari and Windows auth/install/edit/attachment tests |
| 1.9.0 | Dec 25–29 | Reminders, widgets, Android sharing and ABI builds, scheduled/encrypted backups, exports | Reminder restart/timezone, backup restore and supported ABI checks |
| 2.0.0 | Dec 29–30 | Hardening, documentation, public offline distribution if viable; no last-minute major features | Integrated migration/security/recovery/performance checks, signed packages and real updater |

## Architecture and sequencing

Retain Flutter/Dart, native encrypted SQLite, Cloudflare Worker and Neon. Native clients remain offline-first. Browser starts online-first; design its storage and authentication separately from native adapters. Do not rewrite the app or change the document format just to add features.

Prioritize reliable storage and sync before editor collaboration. Prototype Quill Delta operational transformation and authoritative ordering/replay; evaluate an established CRDT only if necessary. Durable Object WebSockets are a candidate for throttled live updates, not a decided deployment. Benchmark resource usage and validate offline convergence before replacing Review edits. Keep recoverable conflicts if automatic merging cannot be demonstrated safe. Object storage is a candidate for attachment performance; do not migrate production blobs without tested recovery and verified free-tier capacity.

Workspace authorization must apply to notes, search, folders, Trash, history, messages, attachment access and every API/CLI/MCP request. Personal workspaces cannot be accessed by agents. Use revocable scoped agent identities, not database credentials. Offline agent messages queue; Notes does not start agent processes.

## Development and release gates

- Each release begins with a current-tree inspection, scoped plan and owner Go. This roadmap PR alone authorizes no application work.
- Use the existing [agent tooling](AGENT_TOOLING.md): independent worktrees, ownership, concise handovers, one integration owner for shared migrations/protocol/editor state. Prefer two to four genuinely independent workers initially. No account details or secrets in Git.
- Codex may lead implementation; Claude can coordinate complex work with Codex workers. Antigravity can handle suitable UI/web work and review; OpenCode is an optional extra harness. Choose models and reasoning effort at kickoff. Prefer existing subscription capacity; existing prepaid balances may be used where useful, with no purchases or automatic paid fallback. No additional infrastructure spending.
- Implement the current release only. Read-only preparation of later releases is allowed. Broader parallel implementation across versions remains open until explicitly approved. Publish and verify releases sequentially.
- Reproduce defects before changes; add focused regressions and test old databases/peers. Use synthetic data and isolated backend. Run full relevant Flutter and Worker checks, package smoke checks, and independent review on exact candidate SHA. Record actual commands, results and skips.
- Finish all autonomous work before requesting consolidated manual device checks. Owner approval is required for merges, signing/publication, production deployment and installs on owner devices; preserve existing release procedures.
- Update product, architecture, decisions and tests with behavior changes. Do not mark tasks complete without evidence. Keep version numbers and updater trust intact.

## Beyond v2.0 and open placement

Editable tables after editor stabilization; offline iPhone web after online version; Android tablet-specific layout after Windows and iPad; calendar export; recovery keys after backup improvements; advanced agent task assignment; rich link previews on request plus opt-in automation; broader self-hosted sync packaging. English only. No app lock, screenshot shield, slash commands, Google Keep import, encrypted legacy Notebook import or new LAN features. No automated agent launching under the current requirements.

Auto-trash with fresh grace for existing items and battery-aware Android background sync are accepted; v1.9.0 is a candidate, exact placement remains open. Optional image compression and performance work require measurements. First-install motion, history retention details, background image storage, notification permissions and dependency choices need release-specific validation. Public offline build must not depend on private cloud identity. No obligation to ship a feature merely to meet the date.

See the [backlog](BACKLOG.md) for individual inventory decisions, evidence and audit overlap.
