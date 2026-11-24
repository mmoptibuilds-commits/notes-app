import { readdir, readFile } from "node:fs/promises";
const connection = process.env.DATABASE_URL;
if (!connection) throw new Error("DATABASE_URL is required");
const endpoint = `https://${new URL(connection).hostname}/sql`;
async function query(queries) {
  const r = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Neon-Connection-String": connection,
      "Neon-Raw-Text-Output": "true",
      "Neon-Array-Mode": "true",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(
      Array.isArray(queries)
        ? { queries: queries.map((query) => ({ query, params: [] })) }
        : { query: queries, params: [] },
    ),
  });
  if (!r.ok) throw new Error(`Neon SQL request failed (${r.status})`);
  return r.json();
}
function split(sql) {
  const out = [];
  let start = 0,
    quote = "",
    dollar = "";
  for (let i = 0; i < sql.length; i++) {
    if (dollar) {
      if (sql.startsWith(dollar, i)) {
        i += dollar.length - 1;
        dollar = "";
      }
      continue;
    }
    if (quote) {
      if (sql[i] === quote) {
        if (sql[i + 1] === quote) i++;
        else quote = "";
      }
      continue;
    }
    if (sql[i] === "'" || sql[i] === '"') {
      quote = sql[i];
      continue;
    }
    if (sql[i] === "$") {
      const m = sql.slice(i).match(/^\$[A-Za-z_0-9]*\$/);
      if (m) {
        dollar = m[0];
        i += dollar.length - 1;
        continue;
      }
    }
    if (sql[i] === ";") {
      const s = sql.slice(start, i).trim();
      if (s) out.push(s);
      start = i + 1;
    }
  }
  const last = sql.slice(start).trim();
  if (last) out.push(last);
  return out;
}
await query(
  "CREATE TABLE IF NOT EXISTS schema_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
);
for (const file of (await readdir(new URL("../migrations/", import.meta.url)))
  .filter((x) => x.endsWith(".sql"))
  .sort()) {
  const version = file.slice(0, 4),
    check = await query(`SELECT version FROM schema_migrations WHERE version='${version}'`);
  if (check.rows?.length) continue;
  const statements = split(
    await readFile(new URL(`../migrations/${file}`, import.meta.url), "utf8"),
  );
  statements.push(
    `INSERT INTO schema_migrations(version) VALUES('${version}') ON CONFLICT DO NOTHING`,
  );
  await query(statements);
  console.log(`applied ${version}`);
}
