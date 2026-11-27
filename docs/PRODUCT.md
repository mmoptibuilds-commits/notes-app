# Product requirements

Notes replaces the note-taking part of Everything App ("Note Book") for one
person across up to five of their own devices. Speed, compact layouts,
simplicity and intuitive editing matter more than feature count.

## Platforms

- Android (target device: Nothing Phone (2)).
- Native Linux (CachyOS, GNOME, Wayland).
- Keep iOS and web possible; do not build them.

## Accepted features

### Library
- Compact cards; grid, masonry and list layouts; responsive column count.
- Folders (flat), pinned notes, archive, recoverable Trash.
- Starts in Unfiled by default; Settings can choose Unfiled, All notes or Last
  viewed.
- With no folders, Unfiled opens as All notes because every note is unfiled.
- Bulk operations: pin, archive, move to folder, trash, restore, delete forever.
- Fast full-text search across title and body.
- Library scroll position survives opening and closing a note.

### Editor
- New note opens instantly, untitled; autosave with no save button.
- Rich text stored as Quill Delta: headings, bold/italic/underline/strike,
  lists, checklists, quotes, code blocks, inline code, links, images.
- Markdown import and export.
- One-tap copy of the whole note.
- Customisable toolbar (which buttons, in what order).
- Completed checklist items move to a collapsible "completed" section with
  per-item restore/delete and bulk uncheck/delete. The stored document keeps
  every line with its formatting; opening a note never rewrites it.
- Cursor and scroll position are never reset by autosave, resume or sync.
- Long documents stay usable.

### Appearance
- AMOLED black (default), charcoal, light.
- Several bundled fonts plus the system font; adjustable text size.
- Animation intensity: off, reduced, full. The system reduced-motion preference
  disables app animations without changing the saved intensity setting.
- Minimal navigation; advanced controls tucked away.
- Desktop: keyboard shortcuts, context menus, hover, resizable window.

### Updates
- Check for stable releases automatically and download verified updates in the
  background when automatic updates are enabled.
- Always ask the user to confirm installation. Android uses the system package
  installer; Linux in-app updates support managed installs and relaunch Notes.
- Preserve the existing signed-manifest and platform-signing trust checks.

### Sync
- Up to five of the owner's devices on Android and Linux.
- Each device fully usable offline; changes queue durably.
- QR-based authenticated pairing (Linux shows a code; paste fallback where
  there is no camera).
- Catch-up on open/resume when a peer is reachable; manual sync; quiet status.
- Syncs note content, metadata, folders, checklist state, trash and deletions.
- LAN sync is direct and encrypted. Optional private cloud sync is off until the
  user signs in with the owner's Google account and explicitly uploads a library.
  The server stores notes as readable JSON, so cloud sync is not end-to-end
  encrypted. LAN sync remains available and unchanged.
- Cloud sync automatically combines non-overlapping edits to different lines.
  Conflicting edits are kept for review; no version is silently dropped.
- Trash is kept until the user empties it.
- LAN first; Tailscale addresses work as ordinary reachable addresses.
- Authenticated encryption, high-entropy keys, peer authorisation, replay
  protection and a versioned protocol apply to LAN sync. Cloud sync uses
  HTTPS and owner-only sign-in.

### Data
- Local SQLite database, encrypted at rest.
- Versioned importer for the legacy Notebook JSON backup: preserves notes and
  metadata, reports what it could not carry over, never duplicates on
  re-import, never overwrites newer local changes, can be rolled back.
- Export of all notes (JSON) and of single notes (Markdown).

## Exclusions

- Upstream finance, health, SMS, AI, media converter, story cards.
- Multi-user accounts, public cloud service, background Android sync, and
  end-to-end encryption for cloud sync.
- iOS and web builds (architecture only).
- Upstream's six-digit-code sync encryption.

## Not built (deliberately)

- Legacy fields without a home (note colour, tags, reminders, lock flag) are
  preserved in the import record and reported, not shown in the UI.
- Note lock / app lock: not requested.
