# Cloud sync (implementation contract)

Status: implementation contract for Notes 1.3.0, checked against the Worker,
Dart client, tests and scripts. Where this file and code disagree, update the
contract to match the shipped behavior and report the difference. It replaces
the "no server" and "no text merge" statements of the LAN-only design (see
D20, D21 in [DECISIONS.md](DECISIONS.md)); LAN sync keeps working unchanged.

## 1. Goals and hard limits

One owner, up to five of their own devices, Android and Linux, offline first.
The design aims to stay within the free plan quotas; actual cost depends on
usage and plan changes. Figures were checked on 2026-11-24:

| Limit | Value | Consequence |
|---|---|---|
| Workers Free requests | 100,000 / day | Polling must be cheap; no per-note requests |
| Worker CPU | 10 ms / request | Server never merges or hashes records/blobs; bounded bodies |
| Worker subrequests | 50 / request | One Neon HTTP call per request is the norm |
| Neon Free compute | 100 CU-hours / project / month, scale to zero after 5 min idle (cannot be disabled) | An idle "anything new?" check must not touch Neon (section 4) |
| Neon Free storage / egress | 1 GB per project, 5 GB per month | Keep the library and response sizes small |
| Durable Objects Free | SQLite-backed classes only | Use `new_sqlite_classes` |

Unified payload limits: a serialized record row is at most **180 KiB**, an
individual attachment is at most **20 MiB**, a push batch is at most 50 rows /
256 KiB, and a change page is requested at 256 KiB (the Worker maximum). The
client leaves oversized notes and attachments locally, reports them in cloud
status, and continues syncing other records. The Worker returns 413 for a row
over 180 KiB. Change-feed rows include an additive `bytes` field containing
`octet_length(row::text)`; clients ignore it when decoding the record itself.

Plan figures were checked against the vendor pages on 2026-11-24:
[Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
and [Neon pricing](https://neon.com/pricing). Recheck them before relying on
the free quotas for a release.

The Worker is a thin, authenticated, revisioned record store with a change
feed and a blob store. **All merging happens in the Dart client**, which already
has `merge.dart`, `RemoteApplier` and their tests. The server can read synced
notes (it stores them as plain JSON); this is a deliberate trade-off for a
single-owner private deployment and is recorded in D20.

## 2. Components

```
Android / Linux app                      Cloudflare Worker (TypeScript)        Neon Postgres
  CloudService (lib/sync/cloud)  --HTTPS-->  routes /v1/*  --HTTP SQL-->  records, blobs, devices
  line merge (lib/doc, lib/sync)             Durable Object "Coordinator"
  platform login (lib/platform)              (head hint + one-time auth codes)
```

Server code: `server/sync/` (TypeScript, no framework, no heavy dependencies; the
bundle is uploaded through the Cloudflare API, so it must stay small).
Two bundles are built from one source: `production` and `test`. Only the test
bundle contains the fake sign-in page and `/v1/test/*` helpers (compile-time
`define`, with a test that greps the production bundle for them).

## 3. Server

### 3.1 Configuration (Worker bindings; never in source)

| Name | Kind | Meaning |
|---|---|---|
| `DATABASE_URL` | secret | Neon connection string of a dedicated low-privilege role |
| `SESSION_SECRET` | secret | 32 random bytes (base64url); HMAC key for access tokens and auth state |
| `OWNER_SUB` | secret | Google account ID (`sub`) allowed to use this server |
| `GOOGLE_CLIENT_ID` | var | public OAuth Web client ID (token `aud`) |
| `PUBLIC_URL` | var | `https://<worker host>` used to build the callback URL |
| `ALLOWED_REDIRECTS` | var | JSON list of app redirect prefixes: `com.mmoptibuilds.notes:/cloud-auth`, `http://127.0.0.1/` (any port, path `/cb`) and, for the test deployment only, the test app scheme |
| `COORDINATOR` | Durable Object namespace | class `Coordinator`, `new_sqlite_classes` |
| `ENVIRONMENT` | var | `production` or `test` |

If `OWNER_SUB` is unset the server is in setup mode: the callback page shows the
signed-in account's own ID and email to that user and issues nothing.

### 3.2 Sign-in (browser flow, no client secret anywhere)

Both platforms use the system browser and Google's OpenID Connect
`response_type=id_token` with `response_mode=form_post` against a Web client
whose only redirect URI is `<PUBLIC_URL>/v1/auth/callback`. If Google refuses
this response type, sign-in is unavailable: this branch implements no code-flow
fallback.

1. App creates a random `verifier`, computes `challenge = base64url(sha256(verifier))`,
   picks a `redirect` (Android: `com.mmoptibuilds.notes:/cloud-auth`; Linux:
   `http://127.0.0.1:<port>/cb` from a one-shot loopback listener) and a random
   `appState`, then opens `GET <PUBLIC_URL>/v1/auth/start?challenge=&redirect=&state=&name=<device name>`.
2. Worker validates `redirect` against `ALLOWED_REDIRECTS`, creates a nonce,
   builds `state = base64url(json{challenge, redirect, appState, nonce, name, exp 10 min}) + "." + hmac`,
   and redirects to `https://accounts.google.com/o/oauth2/v2/auth` with
   `client_id`, `redirect_uri`, `response_type=id_token`, `response_mode=form_post`,
   `scope=openid email`, `nonce`, `state`, `prompt=select_account`.
3. `POST /v1/auth/callback` (form: `id_token`, `state`). Worker verifies the state
   HMAC and expiry, then the ID token: RS256 signature against Google's JWKS
   (cached in memory and Cache API), `iss` is `https://accounts.google.com` or
   `accounts.google.com`, `aud == GOOGLE_CLIENT_ID`, `exp`, `iat` skew of at most
   5 minutes, `nonce` equals the state's nonce, `email_verified == true`, and
   `sub == OWNER_SUB`. Any other account gets a plain "This server is private"
   page and no code. On success it stores `{challenge, name, exp 2 min}` under a
   random one-time `code` in the Coordinator and serves a small HTML page that
   navigates to `redirect?code=<code>&state=<appState>` (a visible "Return to
   Notes" link for browsers that block automatic custom-scheme redirects).
4. `POST /v1/auth/token {code, verifier}`: the Coordinator consumes the code
   atomically; the server checks `sha256(verifier) == challenge`; registers a
   device row (refuses a sixth active device); returns
   `{deviceId, access, accessExp, refresh}`.
5. `POST /v1/auth/refresh {refresh}`: rotates the refresh token (the previous one
   stays valid for 60 s so a lost response can be retried) and returns a new
   access token. `POST /v1/auth/logout` revokes the calling device.
   `GET /v1/devices` and `DELETE /v1/devices/{id}` list and revoke.

Access token: `v1.<base64url payload>.<base64url HMAC-SHA256>`, payload
`{dev, exp}`, lifetime 12 hours, verified with Web Crypto without touching the
database. Refresh tokens use
`r1.<base64url 32 random bytes>.<base64url HMAC-SHA256>`; the HMAC covers
`refresh:<random>` with `SESSION_SECRET`. The Worker verifies this format and
signature before querying Neon, while SQL stores and compares the SHA-256 of
the full token. Random or malformed refresh strings return 401 without database
work. The unauthenticated token exchange reaches Neon only after the
Coordinator consumes a valid one-time code and the PKCE verifier matches;
invalid and replayed exchanges do not reach Neon. Callback uses
Google/Coordinator, while health, auth start and head use no database.
Every non-auth route rejects a missing, malformed, expired or wrongly signed
token **before** any Neon call (the workers.dev URL is public and Neon compute
hours are the scarce resource). Revocation is checked on routes that touch Neon.

Test deployment only: `GET /v1/auth/start` renders a page offering "Sign in as
owner" and "Sign in as another account"; the second signs in with a different
`sub` and must be refused exactly like a real other account.

### 3.3 Records

A record is one note row or one folder row exactly as the app serializes it
(`NoteRecord.toJson`, `FolderRecord.toJson`), wrapped by the server:

```
{ kind: "note"|"folder", id, rev, seq, digest, row: {...} }
```

* `rev`: per-record revision, 1 on first write, +1 on each accepted change.
* `seq`: library-wide change sequence (strictly increasing, see below).
* `digest`: lowercase hex SHA-256 chosen by the client over its own canonical
  encoding of the whole row. It is the idempotency key and the join comparator.
  The server never recomputes it.
* The server does not interpret HLCs, version vectors or registers. It validates
  only shape: `kind`, `id` is a UUID, sizes, and that `row` is a JSON object.

### 3.4 Endpoints (all JSON, bodies limited; errors are `{error, message}`)

| Route | Auth | Neon | Purpose |
|---|---|---|---|
| `GET /v1/health` | no | no | `{ok:true, v:1, env}` |
| `GET /v1/auth/start`, `POST /v1/auth/callback`, `POST /v1/auth/token`, `POST /v1/auth/refresh` | no | token and refresh only | section 3.2 |
| `POST /v1/auth/logout`, `GET /v1/devices`, `DELETE /v1/devices/{id}` | yes | yes | device management |
| `GET /v1/head` | yes | **no** | `{libraryId|null, state, seq}` from the Coordinator |
| `GET /v1/library` | yes | yes | `{libraryId, state, createdAt, seq, counts:{notes,folders,blobs}, uploaderDeviceId}` or 404 when none |
| `POST /v1/library/init` | yes | yes | `{libraryId, deviceId}`: creates the singleton in state `uploading`; 409 with the existing library if there is one |
| `POST /v1/library/ready` | yes | yes | `{libraryId}`: `uploading` to `ready` (joiners require `ready`) |
| `GET /v1/changes?since=&limit=&maxBytes=` | yes | yes | records with `seq > since`, ascending; `{libraryId, rows, next, more, head}`; defaults 50 rows / 256 KiB, maximum 100 / 256 KiB |
| `POST /v1/push` | yes | yes | section 3.5 |
| `GET /v1/manifest?after=&limit=` | yes | yes | `{items:[{kind,id,rev,digest}], next, more}`, ordered by `(kind,id)`, up to 500 items, for the join dry run |
| `POST /v1/blobs/check` | yes | yes | `{hashes:[up to 100]}` returns `{missing:[...], partial:{hash:length}}` |
| `PUT /v1/blobs/{sha256}` | yes | yes | `{offset, size, mime, data}` where `data` is base64 of at most 96 KiB; appends only when `offset` equals the stored length (otherwise returns the stored length so the client resumes); verifies `sha256` in SQL when the last chunk completes the declared `size` and deletes the blob on mismatch |
| `GET /v1/blobs/{sha256}?offset=&limit=` | yes | yes | `{size, mime, offset, data(base64), complete}`, at most 192 KiB per response |
| `POST /v1/test/reset` | test only | yes | empties the library (test deployment only) |

Migration `0002_changes_bytes.sql` adds the per-row `bytes` response field; it
must be applied before deploying the bundle that consumes it. The Worker never decodes or encodes blob bytes: Postgres does
(`encode(substring(...),'base64')`, `decode($1,'base64')`, built-in `sha256()`).

### 3.5 Push (all or nothing, retry safe)

Request `{libraryId, batchId, rows:[{kind, id, baseRev, digest, row}]}`, at most
50 rows and 256 KiB. In one Postgres transaction:

1. Take the library counter row `FOR UPDATE` (this serializes pushes and
   guarantees that `seq` order equals commit order, so a pull cursor can never
   skip a row; there is a test that simulates concurrent pushes).
2. For each row: if the record exists and `baseRev == rev`, write it with
   `rev + 1` and the next `seq`; if it does not exist and `baseRev == 0`, insert
   with `rev = 1`; if the stored `digest` equals the incoming `digest`, report it
   unchanged (idempotent retry, no new `rev` or `seq`); otherwise it is a conflict.
3. If any row conflicts, roll back everything and answer `409`
   `{error:"conflict", conflicts:[full current records]}`. Nothing is committed.
   Otherwise commit and answer `200 {results:[{kind,id,rev,seq,unchanged}], head}`.
4. After commit the Worker advances the Coordinator head to `seq` (retry once;
   a failure is logged and reported as `headStale:true`, the push is still
   committed and clients also re-check Neon periodically, section 4).

A wrong `libraryId` is `409 {error:"library"}`. A library in state `uploading`
accepts pushes only from `uploaderDeviceId`.

### 3.6 Schema and logging

Postgres schema lives in `server/sync/migrations/NNNN_*.sql`, applied by
`server/sync/scripts/migrate` which records applied versions in a table and is
append-only like the app's migrations. Tables: `library` (singleton: id, state,
seq counter, uploader), `records` (`kind,id` key, `rev`, `seq` indexed, `digest`,
`row jsonb`), `blobs` (`hash` key, `mime`, `size`, `data bytea`, `complete`),
`devices` (id, name, refresh hashes, created, last seen, revoked).

Logs are one JSON line per request: request id, route, status, duration, row and
byte counts. Never note titles or bodies, row JSON, tokens, authorization
headers, email, `sub`, or connection strings.

## 4. Why polling does not drain Neon

Each active device polls `GET /v1/head` (Worker plus Coordinator only, no Neon)
every 30 s while the app is running. Android stops polling when paused; Linux
keeps polling while the window is open or minimized. It pulls from Neon only
when `seq` exceeds its cursor. Pushes touch Neon. A real Neon pull occurs at
start, resume, manual sync and at most once an hour while running, which covers
a lost head update. Idle polling does not wake Neon; actual compute use depends
on the user's edits and transfer volume, so this source tree does not claim a
measured monthly total.

## 5. Client (Dart)

### 5.1 Data (migration 4, append only, with an upgrade test)

* `cloud_notes(kind, id, rev, digest, base_title, base_body, base_vv, base_hlc)`:
  per record, the server `rev` and `digest` last agreed with the server, and for
  notes the last cloud-synced content used as the common ancestor of a text merge.
  Written in the same transaction as the cursors.
* Cursors and state live in `local_meta` (device local, never synced):
  `cloud.library_id`, `cloud.pull_seq`, `cloud.push_seq` (local change counter up
  to which rows were pushed), `cloud.state`.
* Production tokens live in `flutter_secure_storage` (entry
  `notes.cloud.session.v1`), never in SQLite or settings. With `NOTES_DATA_DIR`
  set, that instance stores its session in its own plain-text
  `cloud-session.json` file. Treat it as a credential and use only the test
  Worker; do not commit it.

### 5.2 Sync cycle (`CloudSyncEngine`)

1. Pull: `GET /changes?since=pull_seq` page by page. Each page is applied in one
   transaction together with the cursor, `cloud_notes` updates and the local clock
   `observe` calls: rows go through `RemoteApplier`-equivalent merge. When the local
   row is concurrent with the pulled row and a base exists, use
   `threeWayMerge` (section 6). Otherwise use `mergeNotes` (whole-document conflict
   copy). Clock skew guard (2 days) applies as on LAN. Malformed rows are kept
   in bounded quarantine, counted in cloud status, and retried before each later
   pull; a newer version replaces a quarantined copy. The cursor moves past a
   malformed row so it cannot block other records.
2. Push: candidates are rows with `local_seq > push_seq` whose digest differs
   from `cloud_notes.digest` (so rows merely received from the server are not
   echoed back). Send in batches of at most 50 rows / 256 KiB with
   `baseRev = cloud_notes.rev` (0 if absent). On `200`, update `cloud_notes`
   (`rev`, `digest`, new base = what was pushed) and advance `push_seq` in one
   transaction. On `409`, apply the returned conflicts: full current rows are
   merged locally; a `{kind,id,missing:true}` entry clears stale revision
   bookkeeping so that record can be retried as a new insert. Then retry, at
   most 5 rounds, before reporting and backing off.
3. Blobs: for pushed or pulled notes, attachments with missing bytes are fetched
   (verify SHA-256 before storing, as on LAN); local blobs missing on the server
   are checked with `blobs/check` and uploaded in 96 KiB chunks (resume by the
   returned length). Blobs are uploaded before the notes that reference them are
   pushed.
4. Folders are records exactly like notes (kind `folder`), pushed before notes.

Every step is idempotent: replaying a pull page or a push batch changes nothing.
Progress is persisted after each page or batch. Local saves never wait for the
network: the engine runs asynchronously, reads and writes only through
`NoteRepository` / `AppDatabase.transaction`, and a failing sync never blocks or
fails an editor save. Network errors back off (30 s, 2 min, 10 min, 30 min) and
a manual **Sync now** always tries immediately.

### 5.3 Triggers (`CloudService`, a `ChangeNotifier`)

Start and resume, after local edits settle (20 s, like LAN), a poll timer
(section 4), manual. Linux keeps syncing while the window is open or minimized
and stops when the process quits. Android polls while foregrounded and stops
when paused; no background service is used. While cloud is **active** on a
device, LAN auto-sync stops (manual LAN sync stays), otherwise LAN conflict
copies would race cloud merges. Cloud is off by default; the switch and its
state are per device.

### 5.4 Upload and join (opt-in; section 8 of the task, "one upload")

* **Upload** (one device, after an explicit confirmation in the app): first a
  verified backup (existing export written atomically, then re-read, parsed with
  `parseExport` and compared with the same consistent read snapshot of rows,
  attachments and local sequence),
  then `library/init`, blobs, folders and notes in batches (progress persisted;
  resumable after a crash or lost connection), then `library/ready`.
* **Join** (every other device): read-only dry run first. Compare
  `GET /manifest` with local rows by `(kind, id, digest)`, check attachment
  references (`blobs/check` for every hash local notes reference), and folder
  references. Report counts only (identical, only here, only on server,
  differing, missing attachments). Only an exact match may join; on any mismatch
  nothing is written, both copies stay as they are, and the screen shows the
  report. Joining writes bookkeeping only (`cloud_notes`, cursors), then pulls.
  An empty device joins by pulling.

Run the live integration check against an isolated test Worker with
`CLOUD_LIVE_URL=https://<test-worker> flutter test test/live/cloud_live_test.dart`.
Without `CLOUD_LIVE_URL`, it is skipped with an explanatory message.

### 5.5 Sign-in on the device

`lib/platform/cloud_login.dart` hides the platform differences behind
`CloudLoginLauncher.login(startUrl-builder) -> LoginResult(code, state)`:
Android opens the browser with `ACTION_VIEW` and receives
`<app scheme>:/cloud-auth?code=&state=` through an intent filter on `MainActivity`
(method channel, no new package); Linux starts a one-shot
`HttpServer.bind(127.0.0.1, 0)`, opens `xdg-open`, answers one request on
`/cb` with a plain "You can return to Notes" page and closes. The app verifies
`state` equals its `appState` before calling `/auth/token`.

## 6. Merge rules

Server rows are merged on the device that pulls them.

* Content versions: unchanged `mergeNotes` rules (dominates wins; concurrent: later
  HLC wins and the loser is kept as a deterministic conflict copy; equal vector
  with different content keeps both; concurrent edit beats delete-forever).
  New: concurrent versions with identical title, body and purged flag produce no
  conflict copy.
* Text merge (`lib/doc/line_merge.dart`, `lib/sync/three_way.dart`), used only when
  the two sides are concurrent **and** a base exists and the base's vector is
  dominated by both: the canonical Delta is cut into lines (a line is everything
  up to and including its newline, with the newline's block attributes; an image
  embed is part of its line and indivisible); `diff3` runs over lines. Non
  overlapping hunks merge automatically. A conflict is: overlapping hunks, two
  different insertions at the same position, or edits to the same line. Titles are
  merged separately (one side changed: take it; both changed differently:
  conflict). On a conflict the result is the later version as the main note and the
  other becomes the existing deterministic conflict copy (`conflict_of`), which the
  editor surfaces as **Review edits**. Merge output must be a valid Delta ending in
  a newline, and the checklist split/merge invariant must still hold.
* A successful automatic merge is a new content version: vector = pointwise
  maximum plus one increment for the merging device, fresh HLC.
* Registers (pinned, archived, folder, trash, conflict) stay independent LWW
  registers by their own HLCs.
* Required properties (tested): `merge(base, a, a) == a`; `merge(base, base, x) == x`;
  `merge(base, a, b)` equals `merge(base, b, a)` in content; non-overlapping edits
  are never lost; output is a valid Delta ending in `\n`; no text of either side
  is dropped without being preserved as a conflict copy.

Known edge cases: two databases copied from one device can share a device id and
produce equal version vectors with different content. Also, when an automatic
merge keeps a note trashed, the implementation stamps the trash register with
the merge clock so normalization does not restore it. A concurrent offline
restore made before that merge can therefore lose.

## 7. Review edits (UI)

The library never lists conflict copies as ordinary notes. A note with one or
more conflict copies shows a **Review edits** banner in the editor and a small
marker on its card. The review screen shows the main text and each competing
version with changed lines highlighted and offers, per competing version:
**Use this version** (the main becomes that text and the old main is kept as a
conflict copy until dismissed), **Keep both** (promotes the copy to its own note,
existing `keepConflictCopy`), and **Dismiss** (deletes the copy after a
confirmation). Opening or reviewing writes nothing until an action is chosen.

## 8. Rollout and security notes

* Cloud sync is opt-in per device. After upload/join, enabling cloud sync
  suppresses LAN auto-sync on that device; manual LAN sync remains available.
* Only the verified Google account whose `sub` equals `OWNER_SUB` ever receives a
  token. Tokens, refresh hashes, connection strings, `OWNER_SUB` and any email are
  never logged. Private keys and secrets never enter the repository, build
  artifacts, CI or prompts; they exist only as Worker secrets and in the owner's
  password manager.
* Release APK and Linux builds contain the public server URL and public Web
  client ID, nothing secret. Test deployments use a different Worker, a different
  Neon project and a test application id (`com.mmoptibuilds.notes.cloudtest`);
  the production application id is never changed. A `NOTES_DATA_DIR` instance
  has no cloud endpoint unless `NOTES_CLOUD_URL` is explicitly supplied, and
  stores its cloud session in a plain-text file in that directory. Live
  integration tests must target the isolated test Worker.
