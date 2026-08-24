/**
 * Pack MortalShell2Mod into a single package.preload release file.
 *
 * Usage: npm run bundle
 * Output: dist/MortalShell2Mod.bundle.lua
 *
 * Install for players as: Mods/MortalShell2Mod/Scripts/main.lua
 * Contributors keep the multi-file Scripts/ tree for testing.
 *
 * Shared deps are left as external requires (not bundled):
 *   ModMenu.ModMenu, ConfigManager.ConfigManager, UEHelpers.UEHelpers
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "dist", "MortalShell2Mod.bundle.lua");
const ENTRY = "Scripts/main.lua";

const EXTERNAL_OK = new Set([
  "UEHelpers.UEHelpers",
  "ModMenu.ModMenu",
  "ConfigManager.ConfigManager",
]);
const REQUIRE_RE = /require\s*\(\s*["']([^"']+)["']\s*\)/g;

function readLua(relPath) {
  const abs = path.join(ROOT, relPath);
  if (!fs.existsSync(abs)) {
    throw new Error(`Missing source: ${relPath}`);
  }
  return fs.readFileSync(abs, "utf8").replace(/^\uFEFF/, "");
}

function collectRequires(source) {
  const names = new Set();
  for (const match of source.matchAll(REQUIRE_RE)) {
    const name = match[1];
    if (!/^[A-Za-z_][A-Za-z0-9_.]*$/.test(name)) continue;
    names.add(name);
  }
  return names;
}

/** Scripts/*.lua except main.lua — basename is the require() name. */
function discoverModules() {
  const scriptsDir = path.join(ROOT, "Scripts");
  const files = fs
    .readdirSync(scriptsDir, { withFileTypes: true })
    .filter((ent) => ent.isFile() && ent.name.endsWith(".lua") && ent.name !== "main.lua")
    .map((ent) => ent.name)
    .sort();

  return files.map((file) => [path.basename(file, ".lua"), `Scripts/${file}`]);
}

function luaString(s) {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function wrapPreload(name, source) {
  const body = source.replace(/\s*$/, "");
  return `package.preload[${luaString(name)}] = function(...)\n${body}\nend\n`;
}

function main() {
  const MODULES = discoverModules();
  const known = new Set(MODULES.map(([name]) => name));
  const chunks = [];
  const allSources = [];

  chunks.push(`--[[
  MortalShell2Mod.bundle.lua — generated release bundle. Do not edit.

  Build: npm run bundle
  Install as: Mods/MortalShell2Mod/Scripts/main.lua
]]
`);

  for (const [name, relPath] of MODULES) {
    const source = readLua(relPath);
    allSources.push({ name, relPath, source });
    chunks.push(`-- ${relPath}\n`);
    chunks.push(wrapPreload(name, source));
    chunks.push("\n");
  }

  const entrySource = readLua(ENTRY);
  allSources.push({ name: "main", relPath: ENTRY, source: entrySource });

  const requiredByAnyone = new Set();
  for (const { name, relPath, source } of allSources) {
    for (const req of collectRequires(source)) {
      requiredByAnyone.add(req);
      if (EXTERNAL_OK.has(req)) continue;
      if (known.has(req)) continue;
      throw new Error(
        `${relPath}: unexpected require(${JSON.stringify(req)}) — add to EXTERNAL_OK or Scripts/`
      );
    }
  }

  for (const [name, relPath] of MODULES) {
    if (!requiredByAnyone.has(name)) {
      console.warn(`${relPath} is not required by main.lua or any other Scripts module`);
    }
  }

  // Entry is the free chunk so UE4SS loading Scripts/main.lua executes it.
  chunks.push(`-- ${ENTRY} (entry)\n`);
  chunks.push(entrySource.replace(/\s*$/, ""));
  chunks.push("\n");

  const bundled = chunks.join("");
  for (const ext of EXTERNAL_OK) {
    const re = new RegExp(`package\\.preload\\s*\\[\\s*["']${ext.replace(/\./g, "\\.")}`);
    if (re.test(bundled)) {
      throw new Error(`Bundle must not preload ${ext}`);
    }
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, bundled, "utf8");

  const kb = (Buffer.byteLength(bundled, "utf8") / 1024).toFixed(1);
  console.log(`Wrote ${path.relative(ROOT, OUT)} (${MODULES.length} modules + entry, ${kb} KiB)`);
}

try {
  main();
} catch (err) {
  console.error(`bundle failed: ${err.message}`);
  process.exit(1);
}
