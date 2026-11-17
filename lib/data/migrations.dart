/// Schema migrations. Append only: once a version has shipped, its entry never
/// changes. `migrations[i]` upgrades a database from version `i` to `i + 1`.
const List<List<String>> migrations = [_v1];

int get schemaVersion => migrations.length;

const _v1 = <String>[
  // Device-local state: device id and name, clock, change counter.
  '''
  CREATE TABLE local_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  ) WITHOUT ROWID
  ''',
  // Per-device preferences. Never synced.
  '''
  CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  ) WITHOUT ROWID
  ''',
  '''
  CREATE TABLE folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_hlc TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    deleted_hlc TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    local_seq INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX folders_seq ON folders(local_seq)',
  // `pk` gives the search index a rowid that survives VACUUM.
  // plain_text, preview, tasks_* are derived from body on every write.
  '''
  CREATE TABLE notes (
    pk INTEGER PRIMARY KEY,
    id TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL,
    plain_text TEXT NOT NULL DEFAULT '',
    preview TEXT NOT NULL DEFAULT '',
    tasks_total INTEGER NOT NULL DEFAULT 0,
    tasks_done INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    content_hlc TEXT NOT NULL,
    content_vv TEXT NOT NULL,
    purged INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0,
    pinned_hlc TEXT NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0,
    archived_hlc TEXT NOT NULL,
    folder_id TEXT,
    folder_hlc TEXT NOT NULL,
    trashed_at INTEGER,
    trashed_hlc TEXT NOT NULL,
    conflict_of TEXT,
    conflict_hlc TEXT NOT NULL,
    local_seq INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX notes_seq ON notes(local_seq)',
  'CREATE INDEX notes_list ON notes(purged, trashed_at, archived, pinned, updated_at)',
  'CREATE INDEX notes_folder ON notes(folder_id)',
  '''
  CREATE VIRTUAL TABLE notes_fts USING fts5(
    title, plain_text,
    content='notes', content_rowid='pk',
    tokenize='unicode61 remove_diacritics 2',
    prefix='2 3 4'
  )
  ''',
  '''
  CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, plain_text)
    VALUES (new.pk, new.title, new.plain_text);
  END
  ''',
  '''
  CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, plain_text)
    VALUES ('delete', old.pk, old.title, old.plain_text);
  END
  ''',
  '''
  CREATE TRIGGER notes_fts_au AFTER UPDATE OF title, plain_text ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, plain_text)
    VALUES ('delete', old.pk, old.title, old.plain_text);
    INSERT INTO notes_fts(rowid, title, plain_text)
    VALUES (new.pk, new.title, new.plain_text);
  END
  ''',
  // Image bytes, addressed by SHA-256. `data` is NULL while a referenced
  // attachment has not arrived yet.
  '''
  CREATE TABLE attachments (
    hash TEXT PRIMARY KEY,
    mime TEXT NOT NULL,
    size INTEGER NOT NULL,
    data BLOB,
    created_at INTEGER NOT NULL
  )
  ''',
  // Which notes reference which attachments. Derived from bodies.
  '''
  CREATE TABLE note_attachments (
    note_id TEXT NOT NULL,
    hash TEXT NOT NULL,
    PRIMARY KEY (note_id, hash)
  ) WITHOUT ROWID
  ''',
  'CREATE INDEX note_attachments_hash ON note_attachments(hash)',
  '''
  CREATE TABLE import_batches (
    id TEXT PRIMARY KEY,
    format TEXT NOT NULL,
    format_version INTEGER,
    source_name TEXT,
    source_hash TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    rolled_back_at INTEGER,
    report TEXT
  )
  ''',
  // One row per source record per batch. `raw` keeps the source record
  // verbatim so nothing the importer does not understand is lost.
  // `previous` holds the note as it was before an update, for rollback.
  '''
  CREATE TABLE import_records (
    batch_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    note_id TEXT,
    action TEXT NOT NULL,
    raw TEXT,
    previous TEXT,
    PRIMARY KEY (batch_id, source_id)
  ) WITHOUT ROWID
  ''',
  'CREATE INDEX import_records_source ON import_records(source_id)',
];
