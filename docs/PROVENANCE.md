# Provenance review

## Scope and result

I compared this Notes worktree with the supplied read-only snapshot at
`.audit-input/upstream/{lib,assets,pubspec.yaml}`. The snapshot is the
Everything-App (SaadhJawwadh) behavioural reference. Its source has no licence
file; its contents were treated as data and were not copied into this review.

The static comparison found no evidence of copied Dart source code. It did
find one asset in Notes with bytes identical to an upstream asset: Notes
`assets/fonts/Inter.ttf` matches upstream `assets/fonts/Inter-Regular.ttf`
(SHA-256 equality). The relative filenames differ. This proves byte identity,
not who copied from whom: both copies may derive from a separately licensed
Inter font distribution. Notes includes `assets/fonts/Inter-OFL.txt`, but this
comparison cannot establish the history or provenance of either file.

No substantive copied string was identified. The only exact shared Dart string
literals of at least 32 characters were six `package:` import paths and the
common SQL query `SELECT count(*) FROM sqlite_master`. These are technical
identifiers/boilerplate rather than expressive app text.

## Method and counts

- Compared relative file names: Notes has 54 files under `lib/` and upstream
  has 205; one relative path overlaps (`main.dart`). Notes has 16 files under
  `assets/` and upstream has 7; no relative asset paths overlap.
- Computed SHA-256 for each regular file in both asset trees: 1 byte-identical
  pair, the Inter font noted above; 15 Notes asset files had no byte match in
  the upstream tree.
- Normalized Dart source lines by removing all whitespace, discarded lines
  shorter than 12 characters and comment-only lines, then compared consecutive
  runs: 8,940 Notes and 44,563 upstream non-trivial lines; zero matching runs
  of six or more lines.
- Compared exact quoted Dart string literals at least 32 characters long:
  seven distinct values overlap, all six package import paths plus the common
  SQLite metadata count query described above.
- Reviewed the single shared source filename and the high-level structures.
  Notes implements the note-taking subset requested in `docs/PRODUCT.md`,
  using its own repository, encrypted SQLite schema, sync model, and UI. Common
  concepts such as notes, categories/folders, archive, trash, and import are
  required for the compatible feature set. No additional distinctive upstream
  source structure was identified by this static review.

This is a heuristic comparison, not proof of independent creation. It does not
compare compiled binaries, every non-Dart source format, generated build
outputs, visual design, or semantic similarity beyond the checks listed. Lack
of verbatim overlap does not prove independence of design. The exact font
match remains an origin question; the OFL text bundled with Notes is the
locally visible licence evidence.

## Existing project statements and data compatibility

`docs/DECISIONS.md` D12 records that Everything-App has no licence, says no
code was copied and behaviour/data formats were re-implemented, and says the
user reports permission whose scope must be confirmed in writing before
publishing. `docs/PRODUCT.md` likewise says the upstream has no licence,
requires written permission and its redistribution scope before publication,
and says there is to be no public remote until then. The exact Inter font match
above should be considered alongside D12's broad “nothing is copied” statement;
this review does not establish that it came from the upstream author.

The app must read the legacy Notebook backup JSON format, not just its own
`notes-export` format. The importer recognizes Notebook backup versions up to
11. Its root is a JSON object with `version`, `exportedAt`, and data tables
including `notes`, `tags`, `noteTags`, and `deletedNotes`; the app imports the
notes-related tables and reports other non-empty tables as out of scope. Note
rows include legacy identity, title/content, creation and modification times,
pin/archive/deletion state, category, and optional legacy metadata. Content
may be Quill Delta JSON or plain text; image references may point to embedded
backup image files. Unsupported legacy fields are reported/retained in the
import record where applicable. This describes the schema exercised by the
importer. The importer was verified against the user's real backup on 2026-11-20
(44 notes, 0 failures; counts only, content not recorded here).

## Before publication

The project documents currently set a gate: obtain the upstream author's
written permission and scope before any publication. If any material protected
by the upstream author is included or derived, permission must cover the
relevant source and distribution scope. A public source repository and a public
store listing or binary release are both publication/distribution. Continue
to include third-party and font licence texts/notices required by their terms,
including the supplied `quiver` NOTICE. Independent implementation of common
features or compatibility with the legacy JSON format does not by itself
require upstream permission. This static review cannot determine legal rights
in the matching font or the scope of any reported permission. This is not legal
advice.
