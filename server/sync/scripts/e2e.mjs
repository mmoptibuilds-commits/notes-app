import { createHash, randomBytes } from "node:crypto";
const base = process.env.E2E_BASE_URL;
if (!base) throw new Error("E2E_BASE_URL is required");
let checks = 0;
const check = (value) => {
  if (!value) throw new Error("assertion");
  checks++;
};
const b64url = (b) => Buffer.from(b).toString("base64url");
const json = async (path, init = {}) => {
  const r = await fetch(new URL(path, base), init);
  let data = {};
  try {
    data = await r.json();
  } catch {}
  return { status: r.status, data, response: r };
};
const post = (path, body, token) =>
  json(path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
const main = async () => {
  const verifier = b64url(randomBytes(32)),
    challenge = b64url(createHash("sha256").update(verifier).digest()),
    appState = b64url(randomBytes(24));
  const start = new URL("/v1/auth/start", base);
  start.searchParams.set("challenge", challenge);
  start.searchParams.set("redirect", "com.mmoptibuilds.notes.cloudtest:/cloud-auth");
  start.searchParams.set("state", appState);
  start.searchParams.set("name", "Synthetic E2E device");
  const page = await fetch(start);
  check(page.status === 200);
  const html = await page.text(),
    otherHref = html.match(/href="([^"]*account=other)"/)?.[1],
    ownerHref = html.match(/href="([^"]*account=owner)"/)?.[1];
  check(Boolean(otherHref && ownerHref));
  const other = await fetch(new URL(otherHref.replaceAll("&amp;", "&"), base));
  check(other.status === 403);
  const owner = await fetch(new URL(ownerHref.replaceAll("&amp;", "&"), base));
  check(owner.status === 200);
  const returnHtml = await owner.text(),
    code = returnHtml.match(/[?&]code=([A-Za-z0-9_-]+)/)?.[1];
  check(Boolean(code));
  const issued = await post("/v1/auth/token", { code, verifier });
  check(issued.status === 200 && Boolean(issued.data.access));
  const token = issued.data.access;
  const reset = await post("/v1/test/reset", {}, token);
  check(reset.status === 200);
  const initialized = await post("/v1/library/init", {}, token);
  check(initialized.status === 200);
  const libraryId = initialized.data.libraryId;
  const noteId = "11111111-1111-4111-8111-111111111111",
    digest = "a".repeat(64),
    row = { title: "Synthetic E2E row", body: "synthetic data" };
  const pushed = await post(
    "/v1/push",
    {
      libraryId,
      batchId: "initial",
      rows: [{ kind: "note", id: noteId, baseRev: 0, digest, row }],
    },
    token,
  );
  check(pushed.status === 200 && pushed.data.results[0].seq === 1);
  const changes = await json("/v1/changes?since=0", {
    headers: { authorization: `Bearer ${token}` },
  });
  check(
    changes.status === 200 && changes.data.rows.length === 1 && changes.data.rows[0].id === noteId,
  );
  const concurrentIds = [
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333",
  ];
  const concurrent = await Promise.all(
    concurrentIds.map((id, index) =>
      post(
        "/v1/push",
        {
          libraryId,
          batchId: `concurrent-${index}`,
          rows: [
            {
              kind: "folder",
              id,
              baseRev: 0,
              digest: String(index + 2).repeat(64),
              row: { name: `Synthetic ${index}` },
            },
          ],
        },
        token,
      ),
    ),
  );
  check(concurrent.every((x) => x.status === 200));
  const seqs = concurrent.map((x) => x.data.results[0].seq).sort((a, b) => a - b);
  check(seqs[1] === seqs[0] + 1);
  const after = await json("/v1/changes?since=1&limit=100", {
    headers: { authorization: `Bearer ${token}` },
  });
  check(
    after.status === 200 &&
      after.data.rows.length === 2 &&
      after.data.rows[1].seq === after.data.rows[0].seq + 1,
  );
  const bytes = Buffer.from("synthetic blob"),
    hash = createHash("sha256").update(bytes).digest("hex");
  const uploaded = await json(`/v1/blobs/${hash}`, {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      offset: 0,
      size: bytes.length,
      mime: "text/plain",
      data: bytes.toString("base64"),
    }),
  });
  check(uploaded.status === 200 && uploaded.data.complete === true);
  const downloaded = await json(`/v1/blobs/${hash}?offset=0&limit=192`, {
    headers: { authorization: `Bearer ${token}` },
  });
  check(downloaded.status === 200 && Buffer.from(downloaded.data.data, "base64").equals(bytes));
  const ready = await post("/v1/library/ready", { libraryId }, token);
  check(ready.status === 200);
  const loggedOut = await post("/v1/auth/logout", {}, token);
  check(loggedOut.status === 200);
  const refused = await json("/v1/library", { headers: { authorization: `Bearer ${token}` } });
  check(refused.status === 401);
};
try {
  await main();
  console.log(JSON.stringify({ checks, passed: true }));
} catch {
  console.log(JSON.stringify({ checks, passed: false }));
  process.exitCode = 1;
}
