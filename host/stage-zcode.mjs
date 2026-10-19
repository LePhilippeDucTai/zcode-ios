#!/usr/bin/env node
// Assembles a standalone `zcode --web` runtime from an already built ZCode checkout.
//
// Mirrors `stageZCodePackage` from scripts/build-zcode.mjs (ZCode v3.15.1) WITHOUT the
// `stageTuiRuntime` step: it requires a `dist/` for @zcode/shared, a "source only" package,
// and therefore fails. The TUI is not needed for web mode.
//
// It does add the bundled skill pack (`dynamic-workflows`, required by `/workflow`), which
// `stageZCodePackage` leaves out: the agent looks for it next to `zcode.cjs`, in
// `packages/bundled-skills` (bootstrap/src/app/bundled-skills.ts). Same copy as
// `stageBundledSkillPack` in packages/desktop/scripts/prepare-agent-node-bundle.mjs:
// `README.md` + `skills/`, Markdown copied as is (nothing to compile).
//
// Usage: node stage-zcode.mjs <zcode-checkout> <output-dir>

import { chmod, cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [srcArg, outArg] = process.argv.slice(2);
if (!srcArg || !outArg) {
  console.error("Usage: node stage-zcode.mjs <zcode-checkout> <output-dir>");
  process.exit(2);
}
const src = resolve(srcArg);
const out = resolve(outArg);

const { copyRuntimeNodeModules, patchNodePtyPrebuilds } = await import(
  pathToFileURL(resolve(src, "scripts/zcode-distribution/assets.mjs")).href
);

async function mustExist(path, label) {
  if (!(await stat(path).catch(() => null))) throw new Error(`${label} not found: ${path}`);
}

const webDist = resolve(src, "packages/web/dist");
const serverDist = resolve(src, "packages/server/dist");
const cliDist = resolve(src, "apps/zcode-cli/packages/cli/dist");
await mustExist(webDist, "web dist");
await mustExist(resolve(serverDist, "entry-http.js"), "server HTTP entry");
await mustExist(resolve(cliDist, "zcode.cjs"), "bundle agent app-server");
await mustExist(resolve(cliDist, "provider/zcode-builtin.json"), "agent provider config");
const skillPack = resolve(src, "apps/zcode-cli/packages/bundled-skills");
const skillPackRequired = ["SKILL.md", "patterns.md", "examples.md"].map(
  (name) => `skills/dynamic-workflows/${name}`,
);
for (const path of skillPackRequired) {
  await mustExist(resolve(skillPack, path), "bundled skill pack");
}

const { version } = JSON.parse(await readFile(resolve(src, "package.json"), "utf8"));

await rm(out, { force: true, recursive: true });
await mkdir(resolve(out, "agent"), { recursive: true });
await cp(webDist, resolve(out, "web"), { recursive: true });
await cp(serverDist, resolve(out, "server"), { recursive: true });
await cp(resolve(cliDist, "zcode.cjs"), resolve(out, "agent/zcode.cjs"));
await cp(resolve(cliDist, "provider"), resolve(out, "agent/provider"), { recursive: true });
await chmod(resolve(out, "agent/zcode.cjs"), 0o755);
const stagedSkillPack = resolve(out, "agent/packages/bundled-skills");
await mkdir(stagedSkillPack, { recursive: true });
for (const entry of ["README.md", "skills"]) {
  if (await stat(resolve(skillPack, entry)).catch(() => null)) {
    await cp(resolve(skillPack, entry), resolve(stagedSkillPack, entry), { recursive: true });
  }
}
for (const path of skillPackRequired) {
  await mustExist(resolve(stagedSkillPack, path), "copied bundled skill");
}

await copyRuntimeNodeModules(out);
await patchNodePtyPrebuilds(out);

await mkdir(resolve(out, "bin"), { recursive: true });
await cp(resolve(src, "scripts/zcode-distribution/runner.mjs"), resolve(out, "bin/zcode.mjs"));
await chmod(resolve(out, "bin/zcode.mjs"), 0o755);
await writeFile(
  resolve(out, "package.json"),
  JSON.stringify({ name: "zcode-runtime", private: true, type: "module", version }, null, 2),
);

console.log(`[stage-zcode] runtime ${version} ready: ${out}`);
