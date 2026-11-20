# Provenance review

## Evidence and limits

This review uses the Git history available in this worktree, the bundled font
files, and `.audit-input/inter-ref/`. The supplied `.audit-input/upstream/`
snapshot and `.audit-input/licenses/` directory were absent here; package
classifications below remain historical audit evidence. The upstream
comparison was re-run on 2026-11-21 using the available comparison inputs.

The staged Inter 4.1 notes identify the official release and its licence, and
record that `assets/fonts/Inter.ttf` has a different SHA-256 from the staged
4.1 font files. The bundled font's name table is reported as Inter Project,
version `4.001;git-66647c0bb`, with OFL 1.1 metadata. This is consistent with
an Inter 4.0-era build, but the exact upstream build origin is unknown. The
font's file history begins at commit `1717e2a` on 2026-11-17.

The bundled Inter file reports `Version 4.001;git-66647c0bb`, Copyright 2016
The Inter Project Authors, and SIL OFL 1.1 with no Reserved Font Name. Byte
identity with an official Inter release file has not been established; the
comparison found a byte match only with the copy in the upstream app. This is
not a licence blocker.
The app uses the font under the family name `Inter`, does not claim to have
modified it, and bundles its OFL text. The bundled copyright line was corrected
from 2020 to `(c) 2016`, matching the official licence and font metadata. This
is a notice correction, not verification of the font's exact build history.

## Git history review

`git log --format` shows two author identities: `mmoptibuilds
` and `Mohammed Miran`.
The initial project commit is `49e82eb` (`Project foundation and data layer`,
2026-11-17). It added 54 files: Flutter/Android/Linux scaffolding, harness and
product/decision documents, the initial encrypted SQLite schema and repository,
core identifiers/clocks, a small UI shell, and synthetic tests. It was authored
by `mmoptibuilds` and includes a Claude Fable co-author trailer.

`git log --all -- .reference` is empty: no `.reference` path was committed.
The project's ignore rule excludes `.reference/`. The Inter font first appears
in `1717e2a` (`App shell, theme, settings store, keystore bootstrap`), which
also added the other bundled font families. No commit subject explicitly says
that code or assets were copied from Everything-App. Commit subjects and
project files do mention copying in unrelated contexts (for example, copy as
Markdown), and earlier project notes stated that no code was copied.

## Findings by category

### Behaviour and formats implemented in this repository

The history shows Notes' own database, repository, editor, importer, export,
sync, and tests being added in project commits. The legacy Notebook JSON format
is parsed for compatibility; the importer handles notes-related tables and
reports unsupported content. The static review recorded below found no
distinctive copied Dart source structure. These observations support that the
behaviour and formats were implemented in Notes; they are not legal clearance
or proof of independent creation.

### Material matches and open publication items

The 2026-11-21 heuristic comparison found eight byte-identical files of at
least 64 bytes: `assets/fonts/Inter.ttf` and seven standard `flutter create`
scaffold files. It found zero shared normalized six-line Dart runs (91 Notes
files versus 260 upstream files) and 13 shared literals of at least 40
characters: 12 package import paths and one generic sentence. This is not
proof of independent creation. The importer reads the Notebook backup JSON
format for interoperability. The owner reports permission from the upstream
author, but its scope is not confirmed in writing. Publication remains an
owner decision; settle that scope before publication.

### Unknown

The origin of `assets/icon/icon_512.png` and `assets/icon/icon_1024.png` is
undocumented. Before publication, the owner must state whether they created
the icons, generated them, or need permission. This is a separate open
publication item. No legal clearance is claimed.

## Earlier static comparison (historical; date not recorded)

The earlier comparison reported no byte-identical Dart source, one matching
font pair, zero normalized six-line Dart runs, and shared literals limited to
package import paths and a common SQLite metadata query. This evidence is
historical and superseded by the 2026-11-21 count-only rerun above. Both are
heuristics, not proof of independent creation.

The importer reads legacy Notebook backup JSON, including `version`,
`exportedAt`, and notes-related tables such as `notes`, `tags`, `noteTags`, and
`deletedNotes`. Content may be Quill Delta JSON or plain text. Import behaviour
and real-backup counts are described in [the plan](PLAN.md); no private note
content is included in this document.

The reported upstream permission and its scope remain an owner publication
decision. Compatibility with a data format and independent implementation of
common features do not by themselves settle rights. This review is not legal
advice.
