# Provenance review

## Evidence and limits

This review uses the Git history available in this worktree, the bundled font
files, and `.audit-input/inter-ref/`. The supplied `.audit-input/upstream/`
snapshot and `.audit-input/licenses/` directory were absent here, so the
earlier static comparison and package inventory already recorded below are
identified as prior review evidence rather than re-run findings. No contents
from the upstream app were read in this review.

The staged Inter 4.1 notes identify the official release and its licence, and
record that `assets/fonts/Inter.ttf` has a different SHA-256 from the staged
4.1 font files. The bundled font's name table is reported as Inter Project,
version `4.001;git-66647c0bb`, with OFL 1.1 metadata. This is consistent with
an Inter 4.0-era build, but the exact upstream build origin is unknown. The
font's file history begins at commit `1717e2a` on 2026-11-17.

The official Inter licence is OFL 1.1. It contains the standard Reserved Font
Name rule, but no specific Reserved Font Name follows the copyright notice.
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

### Material found copied

The prior static comparison recorded in this document found
`assets/fonts/Inter.ttf` byte-identical to the upstream file named
`assets/fonts/Inter-Regular.ttf`. This establishes a byte match, not the
direction or circumstances of copying. Inter is distributed under OFL 1.1;
the required copyright and licence text are present beside the bundled fonts
and are included in the Linux package. The Android package currently has no
in-app licences page, and the font licence text is not declared as an Android
asset; see [third-party licences](THIRD_PARTY_LICENSES.md).

### Unknown

The exact source/build origin of the byte-matched Inter font, any upstream
author's permission and its scope, and any semantic influence beyond the
documented checks remain unknown. Only written permission from the upstream
author can settle the reported permission's scope. This review makes no claim
of legal clearance.

## Earlier static comparison (recorded before this worktree)

The prior review compared the Notes tree with a supplied Everything-App
snapshot. It reported no byte-identical Dart source and no substantial shared
Dart text. It reported one byte-identical asset pair: Notes
`assets/fonts/Inter.ttf` and upstream `assets/fonts/Inter-Regular.ttf`.
It reported zero matching normalized Dart source runs of six or more lines,
and shared long string literals limited to package import paths and a common
SQLite metadata query. These were heuristic comparisons, not proof of
independent creation. The snapshot is not present in this worktree, so the
comparison was not repeated here.

The importer reads legacy Notebook backup JSON, including `version`,
`exportedAt`, and notes-related tables such as `notes`, `tags`, `noteTags`, and
`deletedNotes`. Content may be Quill Delta JSON or plain text. Import behaviour
and real-backup counts are described in [the plan](PLAN.md); no private note
content is included in this document.

The project must obtain written permission and settle its scope before public
publication or distribution of anything that may be protected by the upstream
author. Compatibility with a data format and independent implementation of
common features do not by themselves settle rights. This review is not legal
advice.
