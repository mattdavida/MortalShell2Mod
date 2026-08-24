/**
 * Build a player-ready MortalShell2Mod zip (no rename required).
 *
 * Usage: npm run deploy
 *
 * Outputs:
 *   dist/MortalShell2Mod.bundle.lua
 *   dist/release/MortalShell2Mod/Scripts/main.lua
 *   dist/release/MortalShell2Mod/enabled.txt
 *   dist/MortalShell2Mod.zip                     — extract into ue4ss/Mods/
 *
 * Shared ModMenu / ConfigManager / UEHelpers are not included.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "dist");
const BUNDLE = path.join(DIST, "MortalShell2Mod.bundle.lua");
const RELEASE_ROOT = path.join(DIST, "release");
const MOD_ROOT = path.join(RELEASE_ROOT, "MortalShell2Mod");
const INSTALL_LUA = path.join(MOD_ROOT, "Scripts", "main.lua");
const ZIP = path.join(DIST, "MortalShell2Mod.zip");

function run(cmd, args, opts = {}) {
  const result = spawnSync(cmd, args, { stdio: "inherit", ...opts });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} exited with ${result.status}`);
  }
}

function zipRelease() {
  fs.rmSync(ZIP, { force: true });

  if (process.platform === "win32") {
    const ps = [
      "Compress-Archive",
      "-Path",
      path.join(RELEASE_ROOT, "*"),
      "-DestinationPath",
      ZIP,
      "-Force",
    ];
    run("powershell", ["-NoProfile", "-Command", ps.join(" ")]);
    return;
  }

  run("zip", ["-r", ZIP, "."], { cwd: RELEASE_ROOT });
}

function main() {
  run(process.execPath, [path.join(ROOT, "tools", "bundle.mjs")], { cwd: ROOT });

  if (!fs.existsSync(BUNDLE)) {
    throw new Error(`Bundle missing after build: ${BUNDLE}`);
  }

  fs.rmSync(RELEASE_ROOT, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(INSTALL_LUA), { recursive: true });
  fs.copyFileSync(BUNDLE, INSTALL_LUA);
  fs.writeFileSync(path.join(MOD_ROOT, "enabled.txt"), "");

  const license = path.join(ROOT, "LICENSE");
  if (fs.existsSync(license)) {
    fs.copyFileSync(license, path.join(MOD_ROOT, "LICENSE"));
  }

  zipRelease();

  const kb = (fs.statSync(ZIP).size / 1024).toFixed(1);
  console.log(`Wrote ${path.relative(ROOT, INSTALL_LUA)}`);
  console.log(`Wrote ${path.relative(ROOT, ZIP)} (${kb} KiB)`);
  console.log("Extract MortalShell2Mod.zip into ue4ss/Mods/ (creates MortalShell2Mod/Scripts/main.lua)");
}

try {
  main();
} catch (err) {
  console.error(`deploy failed: ${err.message}`);
  process.exit(1);
}
