# Notes Cloud Worker

The Worker has no runtime package dependencies. `src/db.ts` uses Neon's SQL-over-HTTP endpoint; its request headers/body were checked against `@neondatabase/serverless@1.0.2`.

All `package.json` dependencies are development-only: TypeScript and Worker
types, PGlite, esbuild, and Vitest. `npm run build` makes two bundles from
`src/worker.ts`: production excludes fake sign-in and `/v1/test/*`; test
includes those helpers only when built with the test flag. Never deploy the test
bundle outside the isolated test Worker and its separate Neon project.

The PGlite concurrency test confirms serialized sequence assignment for competing transactions in its embedded Postgres engine. The E2E script also checks concurrent pushes against a deployed test Worker; that run is needed to cover Cloudflare plus Neon scheduling.

## Build and deploy

Run `npm ci`, `npm run typecheck`, `npm test`, and `npm run build`. The build
writes production and test modules under `dist/`. Apply ordered migrations to
Neon separately with `node scripts/migrate.mjs` using a secret `DATABASE_URL`
in the process environment; deploying the Worker does not apply migrations.
`node scripts/upload-payload.mjs production vars.env` creates upload metadata;
set secret values separately through Cloudflare's secret API. A vars file may
contain only public configuration.

Migrations `0001_initial.sql` and `0002_changes_bytes.sql` are append-only.
Apply any required migration to each database before deploying a Worker
revision that depends on it. Change rows carry an
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
