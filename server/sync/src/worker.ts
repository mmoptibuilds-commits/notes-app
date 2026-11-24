import { NeonDatabase, type Database } from "./db.js";
export { Coordinator } from "./coordinator.js";
import {
  accessToken,
  base64url,
  randomToken,
  readState,
  redirectAllowed,
  sha256,
  signedState,
  verifyAccess,
  verifyGoogleIdToken,
} from "./auth.js";
declare const __TEST_BUILD__: boolean;

export interface Env {
  DATABASE_URL: string;
  SESSION_SECRET: string;
  OWNER_SUB?: string;
  GOOGLE_CLIENT_ID: string;
  PUBLIC_URL: string;
  ALLOWED_REDIRECTS: string;
  ENVIRONMENT: string;
  COORDINATOR: DurableObjectNamespace;
  DB?: Database;
  JWKS_URL?: string;
}
const MAX_BODY = 256 * 1024;
const responseStats = new WeakMap<Response, { rows?: number; bytes?: number }>();
const json = (value: unknown, status = 200) => Response.json(value, { status });
const fail = (error: string, message: string, status: number) => json({ error, message }, status);
async function limitedText(req: Request, limit = MAX_BODY): Promise<string> {
  const length = Number(req.headers.get("content-length") ?? 0);
  if (length > limit) throw new Error("large");
  if (!req.body) return "";
  const reader = req.body.getReader(),
    chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new Error("large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
const parseJson = async (req: Request) => JSON.parse(await limitedText(req)) as Record<string, any>;
const uuid = (s: unknown) =>
  typeof s === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s);
const hash = (s: unknown) => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
const html = (s: string, status = 200) =>
  new Response(s, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
const escapeHtml = (s: string) =>
  s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
const coordinator = (env: Env) => env.COORDINATOR.get(env.COORDINATOR.idFromName("notes"));
const doCall = async <T>(env: Env, path: string, body?: unknown): Promise<T> => {
  const response = await coordinator(env).fetch(
    `https://coordinator${path}`,
    body === undefined
      ? {}
      : {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        },
  );
  if (!response.ok) throw Error("coordinator");
  return response.json() as Promise<T>;
};
const db = (env: Env): Database => env.DB ?? new NeonDatabase(env.DATABASE_URL);
async function requiredDevice(req: Request, env: Env): Promise<{ dev: string } | Response> {
  const authorization = req.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return fail("auth", "Authentication required", 401);
  const token = await verifyAccess(env.SESSION_SECRET, authorization.slice(7));
  if (!token) return fail("auth", "Invalid access token", 401);
  return { dev: token.dev };
}
async function activeDevice(database: Database, device: string) {
  const r = await database.query<{ id: string }>(
    "SELECT id FROM devices WHERE id=$1::uuid AND revoked_at IS NULL",
    [device],
  );
  return r.rows.length > 0;
}
function log(route: string, status: number, start: number, counts: Record<string, number> = {}) {
  const safeRoute = route
    .replace(/^\/v1\/devices\/[0-9a-f-]+$/i, "/v1/devices/:id")
    .replace(/^\/v1\/blobs\/[0-9a-f]{64}$/, "/v1/blobs/:hash");
  console.log(
    JSON.stringify({
      requestId: crypto.randomUUID(),
      route: safeRoute,
      status,
      durationMs: Date.now() - start,
      rows: 0,
      bytes: 0,
      ...counts,
    }),
  );
}

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url),
    path = url.pathname,
    method = req.method;
  if (path === "/v1/health" && method !== "GET") return fail("method", "Method not allowed", 405);
  if (path === "/v1/health" && method === "GET")
    return json({ ok: true, v: 1, env: env.ENVIRONMENT });
  if (path === "/v1/head" && method === "GET") {
    const auth = await requiredDevice(req, env);
    if (auth instanceof Response) return auth;
    return json(await doCall(env, "/head"));
  }
  if (path === "/v1/auth/start" && method === "GET") {
    const challenge = url.searchParams.get("challenge") ?? "",
      redirect = url.searchParams.get("redirect") ?? "",
      appState = url.searchParams.get("state") ?? "",
      name = (url.searchParams.get("name") ?? "Device").slice(0, 80);
    if (
      !/^[A-Za-z0-9_-]{43}$/.test(challenge) ||
      appState.length < 16 ||
      appState.length > 256 ||
      !redirectAllowed(redirect, env.ALLOWED_REDIRECTS)
    )
      return fail("input", "Invalid sign-in request", 400);
    const nonce = randomToken(),
      state = await signedState(env.SESSION_SECRET, {
        challenge,
        redirect,
        appState,
        nonce,
        name,
        exp: Date.now() + 600_000,
      });
    if (__TEST_BUILD__ && env.ENVIRONMENT === "test")
      return html(
        `<!doctype html><h1>Test sign in</h1><a href="/v1/test/signin?state=${encodeURIComponent(state)}&amp;account=owner">Sign in as owner</a><br><a href="/v1/test/signin?state=${encodeURIComponent(state)}&amp;account=other">Sign in as another account</a>`,
      );
    const google = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    google.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
    google.searchParams.set("redirect_uri", `${env.PUBLIC_URL}/v1/auth/callback`);
    google.searchParams.set("response_type", "id_token");
    google.searchParams.set("response_mode", "form_post");
    google.searchParams.set("scope", "openid email");
    google.searchParams.set("nonce", nonce);
    google.searchParams.set("state", state);
    google.searchParams.set("prompt", "select_account");
    return Response.redirect(google, 302);
  }
  if (path === "/v1/auth/callback" && method === "POST") {
    const form = new URLSearchParams(await limitedText(req)),
      idToken = form.get("id_token") ?? "",
      encodedState = form.get("state") ?? "";
    const state = await readState(env.SESSION_SECRET, encodedState);
    if (!state) return html("Invalid sign-in state", 400);
    let claims;
    try {
      claims = await verifyGoogleIdToken(idToken, env, Date.now(), fetch, state.nonce);
    } catch (e) {
      if (e instanceof Error && e.message === "owner") return html("This server is private", 403);
      return html("Sign-in could not be verified", 401);
    }
    if (!env.OWNER_SUB)
      return html(
        `Server setup required. Account ID: ${escapeHtml(claims.sub ?? "")}; email: ${escapeHtml(String((claims as any).email ?? ""))}`,
        403,
      );
    const code = randomToken(24);
    await doCall(env, "/code", {
      code,
      value: { challenge: state.challenge, name: state.name, exp: Date.now() + 120_000 },
    });
    const target = new URL(state.redirect);
    target.searchParams.set("code", code);
    target.searchParams.set("state", state.appState);
    return html(
      `<!doctype html><meta http-equiv="refresh" content="0;url=${target.toString().replaceAll("&", "&amp;").replaceAll('"', "&quot;")}"><p>Return to Notes: <a href="${target.toString().replaceAll("&", "&amp;").replaceAll('"', "&quot;")}">Continue</a></p>`,
    );
  }
  if (
    __TEST_BUILD__ &&
    path === "/v1/test/signin" &&
    method === "GET" &&
    env.ENVIRONMENT === "test"
  ) {
    const account = url.searchParams.get("account"),
      state = await readState(env.SESSION_SECRET, url.searchParams.get("state") ?? "");
    if (!state) return html("Invalid sign-in state", 400);
    if (account !== "owner" || !env.OWNER_SUB) return html("This server is private", 403);
    const code = randomToken(24);
    await doCall(env, "/code", {
      code,
      value: { challenge: state.challenge, name: state.name, exp: Date.now() + 120_000 },
    });
    const target = new URL(state.redirect);
    target.searchParams.set("code", code);
    target.searchParams.set("state", state.appState);
    const link = target.toString().replaceAll("&", "&amp;").replaceAll('"', "&quot;");
    return html(
      `<!doctype html><meta http-equiv="refresh" content="0;url=${link}"><p>Return to Notes: <a href="${link}">Continue</a></p>`,
    );
  }
  if (path === "/v1/auth/token" && method === "POST") {
    const body = await parseJson(req);
    if (
      typeof body.code !== "string" ||
      body.code.length > 128 ||
      typeof body.verifier !== "string" ||
      body.verifier.length < 43 ||
      body.verifier.length > 128
    )
      return fail("input", "Invalid token request", 400);
    const taken = await doCall<{ value?: { challenge: string; name: string; exp: number } }>(
      env,
      "/take",
      { code: body.code },
    );
    const code = taken.value;
    if (!code || code.exp <= Date.now() || (await sha256(body.verifier)) !== code.challenge)
      return fail("auth", "Invalid or expired code", 401);
    const database = db(env),
      refresh = randomToken(),
      digest = await sha256(refresh),
      name = String(code.name).slice(0, 80);
    const inserted = await database.query<{ id: string }>(
      `WITH locked AS (SELECT pg_advisory_xact_lock(88221)), allowed AS (SELECT count(*)<5 AS yes FROM devices,locked WHERE revoked_at IS NULL) INSERT INTO devices(name,refresh_hash) SELECT $1,$2 FROM allowed WHERE yes RETURNING id`,
      [name, digest],
    );
    if (!inserted.rows[0]) return fail("devices", "Device limit reached", 409);
    const deviceId = inserted.rows[0].id,
      exp = Math.floor(Date.now() / 1000) + 12 * 60 * 60,
      access = await accessToken(env.SESSION_SECRET, deviceId, exp);
    return json({ deviceId, access, accessExp: exp, refresh });
  }
  if (path === "/v1/auth/refresh" && method === "POST") {
    const body = await parseJson(req);
    if (typeof body.refresh !== "string") return fail("input", "Invalid refresh request", 400);
    const old = await sha256(body.refresh),
      next = randomToken(),
      nextHash = await sha256(next);
    const result = await db(env).query<{ id: string; current: boolean }>(
      `WITH candidate AS (SELECT id,(refresh_hash=$1) AS current FROM devices WHERE revoked_at IS NULL AND (refresh_hash=$1 OR (previous_refresh_hash=$1 AND previous_until>now())) LIMIT 1 FOR UPDATE) UPDATE devices d SET previous_refresh_hash=CASE WHEN c.current THEN d.refresh_hash ELSE d.previous_refresh_hash END,previous_until=CASE WHEN c.current THEN now()+interval '60 seconds' ELSE d.previous_until END,refresh_hash=CASE WHEN c.current THEN $2 ELSE $1 END,last_seen=now() FROM candidate c WHERE d.id=c.id RETURNING d.id,c.current`,
      [old, nextHash],
    );
    if (!result.rows[0]) return fail("auth", "Invalid refresh token", 401);
    const exp = Math.floor(Date.now() / 1000) + 43200;
    return json({
      deviceId: result.rows[0].id,
      access: await accessToken(env.SESSION_SECRET, result.rows[0].id, exp),
      accessExp: exp,
      refresh: result.rows[0].current ? next : body.refresh,
    });
  }
  if (
    __TEST_BUILD__ &&
    env.ENVIRONMENT === "test" &&
    path === "/v1/test/reset" &&
    method === "POST"
  ) {
    const auth = await requiredDevice(req, env);
    if (auth instanceof Response) return auth;
    const database = db(env);
    if (!(await activeDevice(database, auth.dev))) return fail("auth", "Device revoked", 401);
    await database.query("SELECT sync_reset()");
    try {
      await doCall(env, "/advance", { head: { libraryId: null, state: "empty", seq: 0 } });
    } catch {}
    return json({ ok: true });
  }
  const auth = await requiredDevice(req, env);
  if (auth instanceof Response) return auth;
  const database = db(env),
    inlineRevocation =
      (path === "/v1/push" && method === "POST") ||
      (/^\/v1\/blobs\/[0-9a-f]{64}$/.test(path) && method === "PUT");
  if (!inlineRevocation && !(await activeDevice(database, auth.dev)))
    return fail("auth", "Device revoked", 401);
  if (path === "/v1/library" && method === "GET") {
    const r =
      await database.query<any>(`SELECT l.id AS "libraryId",l.state,l.created_at AS "createdAt",l.seq,
      (SELECT count(*) FROM records WHERE kind='note') AS notes,(SELECT count(*) FROM records WHERE kind='folder') AS folders,
      (SELECT count(*) FROM blobs WHERE complete) AS blobs,l.uploader_device_id AS "uploaderDeviceId" FROM library l WHERE singleton`);
    if (!r.rows[0]) return fail("library", "No library", 404);
    const item = r.rows[0];
    return json({
      libraryId: item.libraryId,
      state: item.state,
      createdAt: item.createdAt,
      seq: Number(item.seq),
      counts: {
        notes: Number(item.notes),
        folders: Number(item.folders),
        blobs: Number(item.blobs),
      },
      uploaderDeviceId: item.uploaderDeviceId,
    });
  }
  if (path === "/v1/library/init" && method === "POST") {
    const id = crypto.randomUUID(),
      result = await database.query<any>(
        `INSERT INTO library(id,state,uploader_device_id) VALUES($1,'uploading',$2) ON CONFLICT(singleton) DO NOTHING RETURNING id`,
        [id, auth.dev],
      );
    if (!result.rows.length) {
      const existing = await database.query<any>(
        'SELECT id AS "libraryId",state,seq FROM library WHERE singleton',
      );
      return json({ error: "exists", library: existing.rows[0] }, 409);
    }
    try {
      await doCall(env, "/advance", { head: { libraryId: id, state: "uploading", seq: 0 } });
    } catch {}
    return json({ libraryId: id, deviceId: auth.dev });
  }
  if (path === "/v1/library/ready" && method === "POST") {
    const b = await parseJson(req);
    if (!uuid(b.libraryId)) return fail("input", "Invalid library id", 400);
    const r = await database.query<any>(
      `UPDATE library SET state='ready' WHERE singleton AND id=$1::uuid AND uploader_device_id=$2::uuid RETURNING id,seq`,
      [b.libraryId, auth.dev],
    );
    if (!r.rows.length) return fail("library", "Library unavailable", 409);
    try {
      await doCall(env, "/advance", {
        head: { libraryId: r.rows[0].id, state: "ready", seq: Number(r.rows[0].seq) },
      });
    } catch {}
    return json({ libraryId: r.rows[0].id });
  }
  if (path === "/v1/push" && method === "POST") {
    const b = await parseJson(req);
    if (
      !uuid(b.libraryId) ||
      !Array.isArray(b.rows) ||
      b.rows.length > 50 ||
      typeof b.batchId !== "string"
    )
      return fail("input", "Invalid batch", 400);
    const seen = new Set<string>();
    for (const row of b.rows) {
      const key = `${row.kind}:${row.id}`;
      if (seen.has(key)) return fail("input", "Duplicate record", 400);
      seen.add(key);
      if (
        !["note", "folder"].includes(row.kind) ||
        !uuid(row.id) ||
        !Number.isInteger(row.baseRev) ||
        row.baseRev < 0 ||
        row.baseRev > 2147483647 ||
        !hash(row.digest) ||
        !row.row ||
        typeof row.row !== "object" ||
        Array.isArray(row.row)
      )
        return fail("input", "Invalid record", 400);
    }
    const result = await database.query<any>(
        "SELECT sync_push($1::uuid,$2::uuid,$3::jsonb) AS result",
        [b.libraryId, auth.dev, JSON.stringify(b.rows)],
      ),
      value = result.rows[0]?.result;
    if (value?.error === "auth") return fail("auth", "Device revoked", 401);
    if (value?.error === "library") return fail("library", "Wrong library", 409);
    if (value?.error === "uploading") return fail("library", "Library is uploading", 409);
    if (value?.conflicts) return json({ error: "conflict", conflicts: value.conflicts }, 409);
    if (value?.error) return fail("input", "Invalid batch", 400);
    try {
      await doCall(env, "/advance", { head: value.head });
    } catch {
      const response = json({ results: value.results, head: value.head, headStale: true });
      responseStats.set(response, {
        rows: b.rows.length,
        bytes: new TextEncoder().encode(JSON.stringify(b.rows)).byteLength,
      });
      return response;
    }
    const response = json({ results: value.results, head: value.head });
    responseStats.set(response, {
      rows: b.rows.length,
      bytes: new TextEncoder().encode(JSON.stringify(b.rows)).byteLength,
    });
    return response;
  }
  if (path === "/v1/changes" && method === "GET") {
    const since = Number(url.searchParams.get("since") ?? "0"),
      rawLimit = Number(url.searchParams.get("limit") ?? 50),
      rawBytes = Number(url.searchParams.get("maxBytes") ?? 204800);
    if (
      !Number.isSafeInteger(since) ||
      since < 0 ||
      !Number.isInteger(rawLimit) ||
      !Number.isInteger(rawBytes)
    )
      return fail("input", "Invalid cursor or page size", 400);
    const limit = Math.min(100, Math.max(1, rawLimit)),
      maxBytes = Math.min(262144, Math.max(1024, rawBytes));
    const r = await database.query<any>("SELECT sync_changes($1,$2) AS result", [since, limit + 1]),
      result = r.rows[0]?.result ?? { rows: [], head: 0 };
    let rows = result.rows as any[],
      kept: any[] = [],
      bytes = 256;
    for (const item of rows) {
      const n = new TextEncoder().encode(JSON.stringify(item)).byteLength + (kept.length ? 1 : 0);
      if (!kept.length && bytes + n > maxBytes)
        return fail("row_too_large", "One record exceeds the requested page size", 413);
      if (kept.length && bytes + n > maxBytes) break;
      kept.push(item);
      bytes += n;
    }
    const next = kept.length ? Number(kept[kept.length - 1].seq) : since,
      response = json({
        libraryId: result.libraryId ?? null,
        rows: kept,
        next,
        more: rows.length > kept.length || (kept.length >= limit && rows.length > limit),
        head: Number(result.head),
      });
    responseStats.set(response, { rows: kept.length, bytes });
    return response;
  }
  if (path === "/v1/manifest" && method === "GET") {
    const after = url.searchParams.get("after") ?? "",
      rawLimit = Number(url.searchParams.get("limit") ?? 500);
    if (!Number.isInteger(rawLimit)) return fail("input", "Invalid page size", 400);
    const limit = Math.min(500, Math.max(1, rawLimit));
    if (after) {
      const parts = after.split(":");
      if (parts.length !== 2 || !["folder", "note"].includes(parts[0]) || !uuid(parts[1]))
        return fail("input", "Invalid manifest cursor", 400);
    }
    const r = await database.query<any>(
      `SELECT kind,id,rev,digest FROM records WHERE (kind,id)>($1,$2::uuid) ORDER BY kind,id LIMIT $3`,
      [
        after.split(":")[0] || "folder",
        after.split(":")[1] || "00000000-0000-0000-0000-000000000000",
        limit + 1,
      ],
    );
    const items = r.rows.slice(0, limit).map((x) => ({ ...x, rev: Number(x.rev) }));
    return json({
      items,
      next: items.length ? `${items.at(-1).kind}:${items.at(-1).id}` : after,
      more: r.rows.length > limit,
    });
  }
  if (path === "/v1/blobs/check" && method === "POST") {
    const b = await parseJson(req);
    if (!Array.isArray(b.hashes) || b.hashes.length > 100 || !b.hashes.every(hash))
      return fail("input", "Invalid hash list", 400);
    const r = await database.query<any>(
        "SELECT hash,octet_length(data) AS length,complete FROM blobs WHERE hash=ANY($1::text[])",
        [b.hashes],
      ),
      have = new Map(r.rows.map((x) => [x.hash, x]));
    return json({
      missing: b.hashes.filter((h: string) => !have.has(h)),
      partial: Object.fromEntries(
        r.rows.filter((x) => !x.complete).map((x) => [x.hash, Number(x.length)]),
      ),
    });
  }
  const blobMatch = path.match(/^\/v1\/blobs\/([0-9a-f]{64})$/);
  if (blobMatch && method === "PUT") {
    const b = await parseJson(req);
    if (
      !Number.isInteger(b.offset) ||
      !Number.isInteger(b.size) ||
      b.offset < 0 ||
      b.size < 0 ||
      b.size > 20 * 1024 * 1024 ||
      b.offset > b.size ||
      typeof b.mime !== "string" ||
      b.mime.length > 256 ||
      typeof b.data !== "string" ||
      b.data.length > 131072 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(b.data)
    )
      return fail("input", "Invalid blob chunk", 400);
    const r = await database.query<any>(
      `SELECT sync_blob_append($1,$2,$3,$4,$5,$6::uuid) AS result`,
      [blobMatch[1], b.offset, b.size, b.mime, b.data, auth.dev],
    );
    const result = r.rows[0]?.result ?? { offset: 0 };
    if (result.error === "auth") return fail("auth", "Device revoked", 401);
    if (result.error === "hash")
      return fail("blob_hash", "Blob hash mismatch; partial data was deleted", 422);
    if (result.error === "size") return fail("blob_size", "Blob size limit exceeded", 413);
    if (result.error === "uploading")
      return fail("library", "Only the uploader can upload during initialization", 409);
    if (result.error === "library") return fail("library", "No library", 404);
    return json(result);
  }
  if (blobMatch && method === "GET") {
    const rawOffset = Number(url.searchParams.get("offset") ?? 0),
      rawLimit = Number(url.searchParams.get("limit") ?? 196608);
    if (!Number.isSafeInteger(rawOffset) || rawOffset < 0 || !Number.isInteger(rawLimit))
      return fail("input", "Invalid blob range", 400);
    const offset = rawOffset,
      limit = Math.min(196608, Math.max(1, rawLimit));
    const r = await database.query<any>(
      `SELECT size,mime,$2::bigint AS offset,replace(encode(substring(data from ($2::bigint+1)::integer for $3::integer),'base64'),chr(10),'') AS data,complete FROM blobs WHERE hash=$1 AND complete`,
      [blobMatch[1], offset, limit],
    );
    return r.rows[0]
      ? json({ ...r.rows[0], size: Number(r.rows[0].size), offset: Number(r.rows[0].offset) })
      : fail("blob", "Blob not found", 404);
  }
  if (path === "/v1/auth/logout" && method === "POST") {
    await database.query("UPDATE devices SET revoked_at=now() WHERE id=$1::uuid", [auth.dev]);
    return json({ ok: true });
  }
  if (path === "/v1/devices" && method === "GET") {
    const r = await database.query<any>(
      'SELECT id,name,created_at AS "createdAt",last_seen AS "lastSeen" FROM devices WHERE revoked_at IS NULL ORDER BY created_at',
    );
    return json({ devices: r.rows });
  }
  const revoke = path.match(/^\/v1\/devices\/([0-9a-f-]+)$/i);
  if (revoke && method === "DELETE") {
    if (!uuid(revoke[1])) return fail("input", "Invalid device id", 400);
    await database.query("UPDATE devices SET revoked_at=now() WHERE id=$1::uuid", [revoke[1]]);
    return json({ ok: true });
  }
  return fail("not_found", "Not found", 404);
}

const handler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const started = Date.now(),
      routeName = new URL(request.url).pathname;
    let response: Response;
    try {
      if (!["GET", "POST", "PUT", "DELETE"].includes(request.method))
        response = fail("method", "Method not allowed", 405);
      else response = await route(request, env);
    } catch (e) {
      response =
        e instanceof Error && e.message === "large"
          ? fail("size", "Request body too large", 413)
          : e instanceof SyntaxError
            ? fail("input", "Malformed JSON", 400)
            : __TEST_BUILD__
              ? json({ error: "server", message: "Request failed", detail: String(e) }, 500)
              : fail("server", "Request failed", 500);
    }
    const size = Number(request.headers.get("content-length") ?? 0),
      stats = responseStats.get(response) ?? {};
    log(routeName, response.status, started, {
      rows: stats.rows ?? 0,
      bytes: stats.bytes ?? (Number.isSafeInteger(size) ? size : 0),
    });
    return response;
  },
};
export default handler;
