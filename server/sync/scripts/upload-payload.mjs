import { writeFile, readFile } from "node:fs/promises";
const envName = process.argv[2];
const first = process.argv.includes("--first");
const args = process.argv.slice(3).filter((a) => a !== "--first");
if (!["production", "test"].includes(envName))
  throw new Error("usage: node scripts/upload-payload.mjs production|test [vars-file] [--first]");
const vars = {};
if (args[0])
  for (const line of (await readFile(args[0], "utf8")).split(/\r?\n/)) {
    const m = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (m) vars[m[1]] = m[2];
  }
const publicVars = ["GOOGLE_CLIENT_ID", "PUBLIC_URL", "ALLOWED_REDIRECTS"];
const metadata = {
  main_module: "worker.production.js",
  compatibility_date: "2026-11-24",
  bindings: [
    { type: "durable_object_namespace", name: "COORDINATOR", class_name: "Coordinator" },
    { type: "plain_text", name: "ENVIRONMENT", text: envName },
    ...Object.entries(vars)
      .filter(([name]) => publicVars.includes(name))
      .map(([name, text]) => ({ type: "plain_text", name, text })),
  ],
  // Durable Object class migration: only on the very first upload of a Worker name.
  ...(first ? { migrations: { new_tag: "v1", new_sqlite_classes: ["Coordinator"] } } : {}),
  secret_placeholders: {
    DATABASE_URL: "<set separately>",
    SESSION_SECRET: "<set separately>",
    OWNER_SUB: "<set separately>",
  },
};
metadata.main_module = `worker.${envName}.js`;
await writeFile(
  new URL(`../dist/${envName}.metadata.json`, import.meta.url),
  JSON.stringify(metadata, null, 2) + "\n",
);
console.log(`wrote dist/${envName}.metadata.json`);
