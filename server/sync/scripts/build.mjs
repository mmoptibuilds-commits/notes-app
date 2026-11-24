import { build } from "esbuild";
import { mkdir, stat } from "node:fs/promises";
await mkdir(new URL("../dist/", import.meta.url), { recursive: true });
for (const mode of ["production", "test"]) {
  const outfile = new URL(`../dist/worker.${mode}.js`, import.meta.url);
  await build({
    entryPoints: [new URL("../src/worker.ts", import.meta.url).pathname],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    outfile: outfile.pathname,
    minify: true,
    treeShaking: true,
    define: { __TEST_BUILD__: mode === "test" ? "true" : "false" },
    legalComments: "none",
  });
  console.log(`${mode}: ${(await stat(outfile)).size} bytes`);
}
