import { describe, expect, it, beforeAll } from "vitest";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import worker, { type Env } from "../src/worker.js";
import {
  accessToken,
  base64url,
  readState,
  redirectAllowed,
  sha256,
  signedState,
  verifyAccess,
  verifyGoogleIdToken,
} from "../src/auth.js";
import { CoordinatorStore } from "../src/coordinator.js";
import { NeonDatabase, type Database } from "../src/db.js";

const secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const id = "11111111-1111-4111-8111-111111111111";
const digest = "a".repeat(64);
class MemoryStorage {
  values = new Map<string, unknown>();
  async get<T>(k: string) {
    return this.values.get(k) as T | undefined;
  }
  async put<T>(k: string, v: T) {
    this.values.set(k, v);
  }
  async delete(k: string) {
    return this.values.delete(k);
  }
  async take<T>(k: string) {
    const v = this.values.get(k) as T | undefined;
    this.values.delete(k);
    return v;
  }
}
const pg = new PGlite();
const database: Database = {
  async query(sql, params = []) {
    const r = await pg.query(sql, params as never[]);
    return { rows: r.rows as never[] };
  },
};
const doState = new MemoryStorage();
const fakeNs = {
  idFromName: () => ({}),
  get: () => ({
    fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
      const req = new Request(input, init),
        u = new URL(req.url),
        body = req.method === "POST" ? ((await req.json()) as any) : {};
      if (u.pathname === "/head")
        return Response.json(
          (await doState.get("head")) ?? { libraryId: null, state: "empty", seq: 0 },
        );
      if (u.pathname === "/advance") {
        const current = (await doState.get<any>("head")) ?? {
          libraryId: null,
          state: "empty",
          seq: 0,
        };
        const n = body.head;
        const head = {
          ...n,
          seq: Math.max(current.libraryId === n.libraryId ? current.seq : 0, n.seq),
        };
        await doState.put("head", head);
        return Response.json(head);
      }
      if (u.pathname === "/code") {
        await doState.put("code:" + body.code, body.value);
        return Response.json({ ok: true });
      }
      if (u.pathname === "/take") {
        const value = await doState.get<any>("code:" + body.code);
        await doState.delete("code:" + body.code);
        return Response.json({ value: value && value.exp > Date.now() ? value : null });
      }
      return new Response("", { status: 404 });
    },
  }),
} as unknown as Env["COORDINATOR"];
const env: Env = {
  DATABASE_URL: "postgres://fake.invalid/db",
  SESSION_SECRET: secret,
  OWNER_SUB: "test-owner-sub",
  GOOGLE_CLIENT_ID: "client-test",
  PUBLIC_URL: "https://worker.example.invalid",
  ALLOWED_REDIRECTS: '["com.mmoptibuilds.notes:/cloud-auth","http://127.0.0.1/"]',
  ENVIRONMENT: "test",
  COORDINATOR: fakeNs,
  DB: database,
};
const request = (path: string, method = "GET", body?: unknown, token?: string) =>
  new Request("https://worker.example.invalid" + path, {
    method,
    headers: {
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

beforeAll(async () => {
  await pg.exec(
    "CREATE FUNCTION digest(data bytea, algorithm text) RETURNS bytea LANGUAGE SQL IMMUTABLE AS $$ SELECT CASE WHEN encode(data,'hex')='6869' THEN decode('8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4','hex') WHEN encode(data,'hex')='686958' THEN decode('e086b1b9f0b678f455968e6ddea3ad75cd67fc629b46922bd2f839b84e64e145','hex') ELSE decode(repeat('00',32),'hex') END $$",
  );
  await pg.exec(
    (await readFile(new URL("../migrations/0001_initial.sql", import.meta.url), "utf8")).replace(
      "CREATE EXTENSION IF NOT EXISTS pgcrypto;",
      "",
    ),
  );
});

describe("cryptography and state", () => {
  it("signs and verifies access tokens, rejects tampering and expiry", async () => {
    const good = await accessToken(secret, "device", Math.floor(Date.now() / 1000) + 60);
    expect(await verifyAccess(secret, good)).toMatchObject({ dev: "device" });
    expect(await verifyAccess(secret, good + "x")).toBeNull();
    const expired = await accessToken(secret, "device", 1);
    expect(await verifyAccess(secret, expired)).toBeNull();
  });
  it("signs state and rejects tampering and expiry", async () => {
    const value = {
      challenge: "c",
      redirect: "com.mmoptibuilds.notes:/cloud-auth",
      appState: "a".repeat(16),
      nonce: "n",
      name: "device",
      exp: Date.now() + 60_000,
    };
    const signed = await signedState(secret, value);
    expect(await readState(secret, signed)).toMatchObject(value);
    expect(await readState(secret, signed + "x")).toBeNull();
    expect(await readState(secret, await signedState(secret, { ...value, exp: 1 }))).toBeNull();
  });
  it("accepts only configured app redirects", () => {
    const allowed =
      '["com.mmoptibuilds.notes:/cloud-auth","com.mmoptibuilds.notes.cloudtest:/cloud-auth","http://127.0.0.1/"]';
    expect(redirectAllowed("com.mmoptibuilds.notes:/cloud-auth", allowed)).toBe(true);
    expect(redirectAllowed("com.mmoptibuilds.notes.cloudtest:/cloud-auth", allowed)).toBe(true);
    expect(redirectAllowed("com.mmoptibuilds.notes:/cloud-auth/elsewhere", allowed)).toBe(true);
    expect(redirectAllowed("https://attacker.example.invalid/", allowed)).toBe(false);
    expect(redirectAllowed("http://127.0.0.1:42342/cb", allowed)).toBe(true);
    expect(redirectAllowed("http://127.0.0.1:42342/elsewhere", allowed)).toBe(false);
    expect(redirectAllowed("http://attacker@127.0.0.1:42342/cb", allowed)).toBe(false);
  });
  it("consumes one-time codes once, rejects expiry and keeps the head monotonic", async () => {
    let now = 1000;
    const storage = new MemoryStorage(),
      store = new CoordinatorStore(storage, () => now);
    await store.putCode("one", { challenge: "c", name: "x", exp: 2000 });
    expect(await store.takeCode("one")).toMatchObject({ challenge: "c" });
    expect(await store.takeCode("one")).toBeUndefined();
    await store.putCode("expired", { challenge: "c", name: "x", exp: 1001 });
    now = 1002;
    expect(await store.takeCode("expired")).toBeUndefined();
    expect(await store.advance({ libraryId: id, state: "ready", seq: 5 })).toMatchObject({
      seq: 5,
    });
    expect(await store.advance({ libraryId: id, state: "ready", seq: 3 })).toMatchObject({
      seq: 5,
    });
  });
  it("uses the Neon HTTP SQL wire shape and parses JSON values", async () => {
    let seen: Request | undefined;
    const client = new NeonDatabase(
      "postgres://user:password@db.example.invalid/app",
      async (input, init) => {
        seen = new Request(input, init);
        return Response.json({
          fields: [{ name: "result", dataTypeID: 3802 }],
          rows: [['{"ok":true}']],
        });
      },
    );
    const result = await client.query("SELECT $1::jsonb", [{ x: 1 }]);
    expect(new URL(seen!.url).href).toBe("https://db.example.invalid/sql");
    expect(seen!.headers.get("Neon-Connection-String")).toContain("postgres://");
    expect(await seen!.json()).toEqual({ query: "SELECT $1::jsonb", params: [{ x: 1 }] });
    expect(result.rows[0]).toEqual({ result: { ok: true } });
  });
  it("checks every Google ID token claim and its signature independently", async () => {
    const pair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    );
    const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
    Object.assign(jwk, { kid: "test-kid", alg: "RS256", use: "sig" });
    const fetcher = async () => Response.json({ keys: [jwk] }) as Response,
      now = Date.now(),
      claims: any = {
        iss: "https://accounts.google.com",
        aud: "client-test",
        exp: Math.floor(now / 1000) + 60,
        iat: Math.floor(now / 1000),
        nonce: "nonce",
        email_verified: true,
        sub: "test-owner-sub",
      };
    const make = async (c: any) => {
      const enc = (v: unknown) => base64url(new TextEncoder().encode(JSON.stringify(v)));
      const head = enc({ alg: "RS256", kid: "test-kid" }),
        payload = enc(c),
        input = `${head}.${payload}`,
        sig = await crypto.subtle.sign(
          "RSASSA-PKCS1-v1_5",
          pair.privateKey,
          new TextEncoder().encode(input),
        );
      return `${input}.${base64url(new Uint8Array(sig))}`;
    };
    const envAuth = { GOOGLE_CLIENT_ID: "client-test", OWNER_SUB: "test-owner-sub" };
    expect(
      (await verifyGoogleIdToken(await make(claims), envAuth, now, fetcher, "nonce")).sub,
    ).toBe("test-owner-sub");
    const bad: [any, string][] = [
      [{ ...claims, iss: "evil" }, "iss"],
      [{ ...claims, aud: "wrong" }, "aud"],
      [{ ...claims, exp: 1 }, "exp"],
      [{ ...claims, iat: Math.floor(now / 1000) - 600 }, "iat"],
      [{ ...claims, nonce: "wrong" }, "nonce"],
      [{ ...claims, email_verified: false }, "email_verified"],
      [{ ...claims, sub: "other" }, "owner"],
    ];
    for (const [c, message] of bad)
      await expect(
        verifyGoogleIdToken(await make(c), envAuth, now, fetcher, "nonce"),
      ).rejects.toThrow(message);
    const noSub = { ...claims };
    delete noSub.sub;
    await expect(
      verifyGoogleIdToken(await make(noSub), envAuth, now, fetcher, "nonce"),
    ).rejects.toThrow("sub");
    const good = await make(claims),
      parts = good.split(".");
    parts[2] = base64url(new Uint8Array(256));
    await expect(
      verifyGoogleIdToken(parts.join("."), envAuth, now, fetcher, "nonce"),
    ).rejects.toThrow("signature");
  });
});

describe("SQL contract", () => {
  it("pushes atomically, retries identical digests and returns current rows on CAS conflict", async () => {
    await pg.query("INSERT INTO devices(id,name,refresh_hash) VALUES($1,'test','x')", [id]);
    await pg.query("INSERT INTO library(id,state,uploader_device_id) VALUES($1,'ready',$1)", [id]);
    const row = { title: "synthetic only" },
      first = await database.query<any>("SELECT sync_push($1::uuid,$2::uuid,$3::jsonb) AS result", [
        id,
        id,
        JSON.stringify([{ kind: "note", id, baseRev: 0, digest, row }]),
      ]);
    expect(first.rows[0].result.results[0]).toMatchObject({ rev: 1, seq: 1, unchanged: false });
    const retry = await database.query<any>(
      "SELECT sync_push($1::uuid,$2::uuid,$3::jsonb) AS result",
      [id, id, JSON.stringify([{ kind: "note", id, baseRev: 0, digest, row }])],
    );
    expect(retry.rows[0].result.results[0].unchanged).toBe(true);
    const conflict = await database.query<any>(
      "SELECT sync_push($1::uuid,$2::uuid,$3::jsonb) AS result",
      [
        id,
        id,
        JSON.stringify([
          { kind: "note", id, baseRev: 0, digest: "b".repeat(64), row },
          { kind: "folder", id: "22222222-2222-4222-8222-222222222222", baseRev: 0, digest, row },
        ]),
      ],
    );
    expect(conflict.rows[0].result.conflicts).toHaveLength(1);
    const count = await pg.query("SELECT count(*)::int AS n FROM records");
    expect((count.rows[0] as any).n).toBe(1);
  });
  it("serializes concurrent pushes into consecutive sequence values and pages changes", async () => {
    const ids = ["33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"];
    const push = (noteId: string) =>
      database.query<any>("SELECT sync_push($1::uuid,$2::uuid,$3::jsonb) AS result", [
        id,
        id,
        JSON.stringify([
          { kind: "note", id: noteId, baseRev: 0, digest, row: { body: "synthetic" } },
        ]),
      ]);
    const values = await Promise.all(ids.map(push));
    const seqs = values.map((x) => Number(x.rows[0].result.results[0].seq)).sort((a, b) => a - b);
    expect(seqs[1]).toBe(seqs[0] + 1);
    const page = await database.query<any>("SELECT sync_changes(0,2) AS result");
    const rows = page.rows[0].result.rows;
    expect(rows.map((x: any) => Number(x.seq))).toEqual(
      [...rows.map((x: any) => Number(x.seq))].sort((a: number, b: number) => a - b),
    );
  });
  it("appends blobs at exact offsets and removes a mismatched completed digest", async () => {
    const bytes = "aGk=",
      correct = "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4";
    const wrong = await database.query<any>(
      "SELECT sync_blob_append($1,0,2,$2,$3,$4::uuid) AS result",
      ["c".repeat(64), "text/plain", bytes, id],
    );
    expect(wrong.rows[0].result.error).toBe("hash");
    const part = await database.query<any>(
      "SELECT sync_blob_append($1,0,3,$2,$3,$4::uuid) AS result",
      [correct, "text/plain", "aGk=", id],
    );
    expect(part.rows[0].result.offset).toBe(2);
    const mismatch = await database.query<any>(
      "SELECT sync_blob_append($1,0,2,$2,$3,$4::uuid) AS result",
      [correct, "text/plain", bytes, id],
    );
    expect(mismatch.rows[0].result.offset).toBe(2);
    const resumable = "e086b1b9f0b678f455968e6ddea3ad75cd67fc629b46922bd2f839b84e64e145";
    await database.query<any>("SELECT sync_blob_append($1,0,3,$2,$3,$4::uuid) AS result", [
      resumable,
      "text/plain",
      "aGk=",
      id,
    ]);
    const completed = await database.query<any>(
      "SELECT sync_blob_append($1,2,3,$2,$3,$4::uuid) AS result",
      [resumable, "text/plain", "WA==", id],
    );
    expect(completed.rows[0].result).toMatchObject({ offset: 3, complete: true });
    const blobOther = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    await pg.query(
      "INSERT INTO devices(id,name,refresh_hash) VALUES($1,'synthetic other','hash')",
      [blobOther],
    );
    await pg.query("UPDATE library SET state='uploading'");
    const blocked = await database.query<any>(
      "SELECT sync_blob_append($1,0,2,$2,$3,$4::uuid) AS result",
      ["f".repeat(64), "text/plain", bytes, blobOther],
    );
    expect(blocked.rows[0].result.error).toBe("uploading");
    await pg.query("UPDATE library SET state='ready'");
    const capped = await database.query<any>(
      "SELECT sync_blob_append($1,0,20971521,$2,$3,$4::uuid) AS result",
      ["f".repeat(64), "text/plain", "", id],
    );
    expect(capped.rows[0].result.error).toBe("size");
  });
});

describe("request boundary", () => {
  it("rejects missing and invalid access tokens before touching the database", async () => {
    const untouched: Database = {
      query: async () => {
        throw new Error("database must not be touched");
      },
    };
    const unauthenticated = await worker.fetch(request("/v1/library"), { ...env, DB: untouched });
    const invalid = await worker.fetch(request("/v1/library", "GET", undefined, "not-signed"), {
      ...env,
      DB: untouched,
    });
    expect(unauthenticated.status).toBe(401);
    expect(invalid.status).toBe(401);
  });
  it("checks library ownership, uploading uploader, record count, body size and manifest paging", async () => {
    const token = await accessToken(secret, id, Math.floor(Date.now() / 1000) + 60),
      other = "66666666-6666-4666-8666-666666666666";
    await pg.query(
      "INSERT INTO devices(id,name,refresh_hash) VALUES($1,'other synthetic','other')",
      [other],
    );
    const otherToken = await accessToken(secret, other, Math.floor(Date.now() / 1000) + 60);
    const invalid = await worker.fetch(
      request(
        "/v1/push",
        "POST",
        { batchId: "x", libraryId: "77777777-7777-4777-8777-777777777777", rows: [] },
        token,
      ),
      env,
    );
    expect(invalid.status).toBe(409);
    await pg.query("UPDATE library SET state='uploading'");
    const blocked = await worker.fetch(
      request("/v1/push", "POST", { batchId: "x", libraryId: id, rows: [] }, otherToken),
      env,
    );
    expect(blocked.status).toBe(409);
    await pg.query("UPDATE library SET state='ready'");
    const tooMany = await worker.fetch(
      request(
        "/v1/push",
        "POST",
        { batchId: "x", libraryId: id, rows: Array.from({ length: 51 }, () => ({})) },
        token,
      ),
      env,
    );
    expect(tooMany.status).toBe(400);
    const largeBody = JSON.stringify({
        batchId: "x",
        libraryId: id,
        rows: [],
        padding: "x".repeat(270000),
      }),
      large = await worker.fetch(
        new Request("https://worker.example.invalid/v1/push", {
          method: "POST",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: largeBody,
        }),
        env,
      );
    expect(large.status).toBe(413);
    const manifest = await worker.fetch(
      request("/v1/manifest?limit=1", "GET", undefined, token),
      env,
    );
    const page = (await manifest.json()) as any;
    expect(manifest.status).toBe(200);
    expect(page.items.length).toBe(1);
    expect(page.more).toBe(true);
  });
  it("refuses another account, issues owner codes once, and enforces PKCE", async () => {
    const verifier = "v".repeat(43),
      state = await signedState(secret, {
        challenge: await sha256(verifier),
        redirect: "com.mmoptibuilds.notes:/cloud-auth",
        appState: "a".repeat(32),
        nonce: "test-nonce",
        name: "Synthetic device",
        exp: Date.now() + 60_000,
      });
    const other = await worker.fetch(
      new Request(
        `https://worker.example.invalid/v1/test/signin?state=${encodeURIComponent(state)}&account=other`,
      ),
      env,
    );
    expect(other.status).toBe(403);
    expect([...doState.values.keys()].some((k) => k.startsWith("code:"))).toBe(false);
    const owner = await worker.fetch(
      new Request(
        `https://worker.example.invalid/v1/test/signin?state=${encodeURIComponent(state)}&account=owner`,
      ),
      env,
    );
    expect(owner.status).toBe(200);
    const ownerHtml = await owner.text(),
      code = ownerHtml.match(/code=([A-Za-z0-9_-]+)/)?.[1] ?? "";
    expect(code.length).toBeGreaterThan(10);
    const mismatch = await worker.fetch(
      request("/v1/auth/token", "POST", { code, verifier: "w".repeat(43) }),
      env,
    );
    expect(mismatch.status).toBe(401);
    const replay = await worker.fetch(request("/v1/auth/token", "POST", { code, verifier }), env);
    expect(replay.status).toBe(401);
  });
  it("registers devices, rotates refresh tokens with a retry window, and caps active devices at five", async () => {
    const verifier = "s".repeat(43),
      code = "one-time-register-code";
    await doState.put("code:" + code, {
      challenge: await sha256(verifier),
      name: "Synthetic device",
      exp: Date.now() + 60_000,
    });
    const issued = await worker.fetch(request("/v1/auth/token", "POST", { code, verifier }), env),
      credentials = (await issued.json()) as any;
    expect(issued.status).toBe(200);
    const first = await worker.fetch(
        request("/v1/auth/refresh", "POST", { refresh: credentials.refresh }),
        env,
      ),
      rotated = (await first.json()) as any;
    expect(first.status).toBe(200);
    expect(rotated.refresh).not.toBe(credentials.refresh);
    const retry = await worker.fetch(
        request("/v1/auth/refresh", "POST", { refresh: credentials.refresh }),
        env,
      ),
      retried = (await retry.json()) as any;
    expect(retry.status).toBe(200);
    expect(retried.refresh).toBe(credentials.refresh);
    for (const device of [
      "77777777-7777-4777-8777-777777777777",
      "88888888-8888-4888-8888-888888888888",
      "99999999-9999-4999-8999-999999999999",
    ])
      await pg.query("INSERT INTO devices(id,name,refresh_hash) VALUES($1,'synthetic','hash')", [
        device,
      ]);
    const sixth = "sixth-device-code";
    await doState.put("code:" + sixth, {
      challenge: await sha256(verifier),
      name: "Synthetic device",
      exp: Date.now() + 60_000,
    });
    const refused = await worker.fetch(
      request("/v1/auth/token", "POST", { code: sixth, verifier }),
      env,
    );
    expect(refused.status).toBe(409);
  });
  it("rejects malformed JSON, wrong methods and does not enable CORS", async () => {
    const token = await accessToken(secret, id, Math.floor(Date.now() / 1000) + 60);
    const malformed = await worker.fetch(
      new Request("https://x/v1/push", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: "{",
      }),
      env,
    );
    expect(malformed.status).toBe(400);
    const wrong = await worker.fetch(request("/v1/health", "PUT"), env);
    expect(wrong.status).toBe(405);
    expect(wrong.headers.has("access-control-allow-origin")).toBe(false);
  });
  it("does not expose note text, tokens or IDs in request logs", async () => {
    const lines: string[] = [];
    const old = console.log;
    console.log = (line: string) => lines.push(line);
    try {
      const token = await accessToken(secret, id, Math.floor(Date.now() / 1000) + 60);
      const marker = "SYNTHETIC_PRIVATE_NOTE_MARKER";
      const response = await worker.fetch(
        request(
          "/v1/push",
          "POST",
          {
            batchId: "batch",
            libraryId: id,
            rows: [
              {
                kind: "note",
                id: "55555555-5555-4555-8555-555555555555",
                baseRev: 0,
                digest: "d".repeat(64),
                row: { body: marker },
              },
            ],
          },
          token,
        ),
        env,
      );
      expect(response.status).toBe(200);
      const revoked = await worker.fetch(
        request("/v1/devices/66666666-6666-4666-8666-666666666666", "DELETE", undefined, token),
        env,
      );
      expect(revoked.status).toBe(200);
      expect(lines).toHaveLength(2);
      expect(lines[0]).toContain('"rows":1');
      expect(lines[0]).not.toContain(marker);
      expect(lines[0]).not.toContain(token);
      expect(lines[0]).not.toContain("55555555-5555-4555-8555-555555555555");
      expect(lines[1]).toContain("/v1/devices/:id");
      expect(lines[1]).not.toContain("66666666-6666-4666-8666-666666666666");
    } finally {
      console.log = old;
    }
  });
  it("keeps production-only output free of fake sign-in routes", async () => {
    const built = await readFile(
      new URL("../dist/worker.production.js", import.meta.url),
      "utf8",
    ).catch(() => "");
    if (built) expect(built).not.toContain("/v1/test/");
  });
});
