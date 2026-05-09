#!/usr/bin/env bun
// Stage the npm launcher package into ./dist/npm/zonia-world/.
//
// The launcher is a tiny Node script. At runtime it:
//   1. Detects the platform/arch.
//   2. GETs <server>/releases/manifest.json.
//   3. Looks in $XDG_CACHE_HOME/zonia-world/<platform>-<arch>/ for a binary
//      with the manifest's expected sha256.
//   4. If missing or wrong hash, downloads the binary, verifies the hash,
//      atomically replaces the cached copy.
//   5. Execs the cached binary, forwarding argv.
//
// Binaries themselves live on the server (built into the Docker image and
// served at /releases/*). There is no per-platform npm package any more.
//
// Usage:
//   bun scripts/prepare-npm.ts
//
// Then publish with scripts/publish-npm.sh.

import {
  chmodSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "..");
const distNpm = join(repoRoot, "dist", "npm");
const clientDir = join(repoRoot, "client");

const HOMEPAGE = "https://github.com/jackharrhy/zonia";
const REPO_URL = "git+https://github.com/jackharrhy/zonia.git";
const BUGS_URL = "https://github.com/jackharrhy/zonia/issues";
const DEFAULT_SERVER_HTTP = "https://zonia.harrhy.xyz";

const clientPkg = JSON.parse(
  readFileSync(join(clientDir, "package.json"), "utf8"),
) as { version?: string };
const VERSION = clientPkg.version ?? "0.2.0";

console.log(`Staging zonia-world launcher v${VERSION}`);
console.log(`Default server: ${DEFAULT_SERVER_HTTP}`);

rmSync(distNpm, { recursive: true, force: true });
mkdirSync(distNpm, { recursive: true });

const pkgDir = join(distNpm, "zonia-world");
mkdirSync(pkgDir, { recursive: true });

const cliJs = `#!/usr/bin/env node
// zonia-world launcher.
//
// Fetches the latest client binary from the zonia server (or uses a cached
// copy if the server's sha256 matches what's already on disk), then execs
// it. No bundled binaries — the source of truth lives server-side.
//
// Override the server with ZONIA_SERVER_HTTP (e.g. for self-hosting):
//   ZONIA_SERVER_HTTP=http://localhost:4000 npx zonia-world

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const DEFAULT_SERVER_HTTP = ${JSON.stringify(DEFAULT_SERVER_HTTP)};

function serverHttpBase() {
  const explicit = process.env.ZONIA_SERVER_HTTP;
  if (explicit) return explicit.replace(/\\/$/, "");
  // Fall back to converting wss://host/socket → https://host if the user only
  // set ZONIA_SERVER (the websocket env var the binary itself reads).
  const ws = process.env.ZONIA_SERVER;
  if (ws) {
    try {
      const u = new URL(ws);
      const proto = u.protocol === "wss:" ? "https:" : "http:";
      return proto + "//" + u.host;
    } catch (_) {
      // fall through
    }
  }
  return DEFAULT_SERVER_HTTP;
}

function cacheDir() {
  // XDG cache spec on Linux/macOS; %LOCALAPPDATA% on Windows; sensible
  // fallback otherwise.
  if (process.platform === "win32" && process.env.LOCALAPPDATA) {
    return path.join(process.env.LOCALAPPDATA, "zonia-world", "Cache");
  }
  const xdg = process.env.XDG_CACHE_HOME;
  if (xdg) return path.join(xdg, "zonia-world");
  return path.join(os.homedir(), ".cache", "zonia-world");
}

function platformKey() {
  return process.platform + "-" + process.arch;
}

function binaryName(plat) {
  return process.platform === "win32" ? "zonia-" + plat + ".exe" : "zonia-" + plat;
}

function fetchJson(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    fetch(url, { signal: ac.signal })
      .then(async (res) => {
        clearTimeout(timer);
        if (!res.ok) {
          reject(new Error("HTTP " + res.status + " for " + url));
          return;
        }
        try {
          resolve(await res.json());
        } catch (e) {
          reject(e);
        }
      })
      .catch((e) => {
        clearTimeout(timer);
        reject(e);
      });
  });
}

async function downloadBinary(url, destPath, expectedSha) {
  const res = await fetch(url);
  if (!res.ok) throw new Error("HTTP " + res.status + " downloading " + url);
  if (!res.body) throw new Error("empty body downloading " + url);

  const tmpPath = destPath + ".tmp." + process.pid;
  const fd = fs.openSync(tmpPath, "w");
  const hash = crypto.createHash("sha256");
  try {
    const reader = res.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      fs.writeSync(fd, value);
      hash.update(value);
    }
  } finally {
    fs.closeSync(fd);
  }

  const actual = hash.digest("hex");
  if (actual !== expectedSha) {
    fs.rmSync(tmpPath, { force: true });
    throw new Error(
      "sha256 mismatch downloading " + url + ": expected " + expectedSha + ", got " + actual,
    );
  }

  // Atomic-ish replace. Last writer wins; harmless because they're writing
  // the same verified bytes.
  fs.renameSync(tmpPath, destPath);
  if (process.platform !== "win32") fs.chmodSync(destPath, 0o755);
}

function sha256File(p) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(p));
  return hash.digest("hex");
}

async function resolveBinary() {
  const plat = platformKey();
  const dir = path.join(cacheDir(), plat);
  fs.mkdirSync(dir, { recursive: true });
  const binPath = path.join(dir, binaryName(plat));

  const server = serverHttpBase();
  let manifest = null;
  try {
    manifest = await fetchJson(server + "/releases/manifest.json", 5000);
  } catch (e) {
    // Manifest fetch failed. If we have a cached binary, run it; otherwise
    // explode with a useful error.
    if (fs.existsSync(binPath)) {
      process.stderr.write(
        "zonia-world: could not reach " + server + " (" + e.message + "), using cached binary.\\n",
      );
      return binPath;
    }
    throw new Error(
      "could not reach " + server + " and no cached binary on disk: " + e.message,
    );
  }

  const entry = manifest && manifest.binaries && manifest.binaries[plat];
  if (!entry || !entry.sha256) {
    throw new Error("no binary for " + plat + " in manifest from " + server);
  }

  const expected = entry.sha256;
  if (fs.existsSync(binPath)) {
    const actual = sha256File(binPath);
    if (actual === expected) return binPath;
    // Cached but stale. Fall through to re-download.
  }

  process.stderr.write("zonia-world: fetching latest " + plat + " binary…\\n");
  await downloadBinary(server + "/releases/" + binaryName(plat), binPath, expected);
  return binPath;
}

(async () => {
  let binPath;
  try {
    binPath = await resolveBinary();
  } catch (e) {
    process.stderr.write("zonia-world: " + e.message + "\\n");
    process.exit(1);
  }

  const child = spawn(binPath, process.argv.slice(2), {
    stdio: "inherit",
    windowsHide: false,
  });
  child.on("exit", (code, signal) =>
    signal ? process.kill(process.pid, signal) : process.exit(code === null ? 0 : code),
  );
  child.on("error", (err) => {
    process.stderr.write("zonia-world: failed to launch binary: " + err.message + "\\n");
    process.exit(1);
  });
})();
`;

writeFileSync(join(pkgDir, "cli.js"), cliJs);
chmodSync(join(pkgDir, "cli.js"), 0o755);

writeFileSync(
  join(pkgDir, "package.json"),
  JSON.stringify(
    {
      name: "zonia-world",
      version: VERSION,
      description: "a world. enter the void.",
      keywords: ["zonia", "tui", "chat", "mud", "phoenix", "opentui"],
      homepage: HOMEPAGE,
      bugs: { url: BUGS_URL },
      repository: { type: "git", url: REPO_URL },
      license: "MIT",
      bin: { "zonia-world": "cli.js" },
      files: ["cli.js", "README.md"],
      engines: { node: ">=18" },
    },
    null,
    2,
  ) + "\n",
);

writeFileSync(
  join(pkgDir, "README.md"),
  `# zonia-world

a world. enter the void.

\`\`\`sh
npx zonia-world
\`\`\`

The launcher fetches the current client binary from \`${DEFAULT_SERVER_HTTP}\`
on first run, caches it under your XDG cache dir, and exec's it. Subsequent
runs check the server's \`releases/manifest.json\` for a new sha256; if
nothing's changed, the cached binary is reused.

## Self-hosting

Override the server with either env var (the launcher accepts both):

\`\`\`sh
# explicit HTTP base
ZONIA_SERVER_HTTP=http://localhost:4000 npx zonia-world

# or the websocket URL the binary itself reads
ZONIA_SERVER=ws://localhost:4000/socket npx zonia-world
\`\`\`

## Quit

\`ctrl-c\`.

## Source

${HOMEPAGE}
`,
);

console.log(`  ✓ zonia-world (${pkgDir})`);
console.log("\nDone. To publish:  ./scripts/publish-npm.sh");
