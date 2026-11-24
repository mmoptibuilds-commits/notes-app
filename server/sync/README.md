# Notes Cloud Worker

The Worker has no runtime package dependencies. `src/db.ts` uses Neon's SQL-over-HTTP endpoint; its request headers/body were checked against `@neondatabase/serverless@1.0.2`.

The PGlite concurrency test confirms serialized sequence assignment for competing transactions in its embedded Postgres engine. The E2E script also checks concurrent pushes against a deployed test Worker; that run is needed to cover Cloudflare plus Neon scheduling.

## Build and deploy

Run `npm ci`, `npm run typecheck`, `npm test`, and `npm run build`. The build writes production and test modules under `dist/`; only deploy the test module to the isolated test Worker and test database. Run `DATABASE_URL=... node scripts/migrate.mjs` to apply ordered, idempotent migrations. `node scripts/upload-payload.mjs production vars.env` creates upload metadata; set the listed secret values separately through the Cloudflare secret API. The vars file must contain only public configuration.

Migration `0002_changes_bytes.sql` is append-only and must be applied to each
database before deploying this Worker revision. Change rows now carry an
additive `bytes` field. Refresh credentials now have the signed form
`r1.<base64url 32-byte random>.<base64url HMAC-SHA256>`; the HMAC signs
`refresh:<random>` with `SESSION_SECRET`, and SQL continues to store the hash
of the complete token. Invalid refresh strings are rejected before Neon. The
token exchange reaches Neon only after the Coordinator consumes a valid
one-time code and the PKCE verifier matches; malformed or replayed exchanges
do not reach Neon. Callback uses Google/Coordinator, while health, auth start
and head use no database.

Set `DATABASE_URL`, `SESSION_SECRET`, and `OWNER_SUB` as Worker secrets. Set `GOOGLE_CLIENT_ID`, `PUBLIC_URL`, `ALLOWED_REDIRECTS`, and `ENVIRONMENT` as vars. Keep database role permissions limited to the sync schema. `SESSION_SECRET` is a base64url encoding of 32 random bytes. To rotate it, replace the secret; this immediately invalidates every access token and auth state. Devices sign in again. To revoke one device, call authenticated `DELETE /v1/devices/{id}`; logout revokes the current device.

The Durable Object stores only the cached library head hint and short-lived one-time authorization codes. Polling `/v1/head` does not query Neon. A stale head is repaired by later pushes or clients' periodic Neon pull.

## Logging

One JSON line is emitted per request with route, status, duration, and optional aggregate counts. The Worker does not log request bodies, note text, row JSON, tokens, authorization headers, emails, account subjects, or database connection strings.
