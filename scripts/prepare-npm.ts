#!/usr/bin/env bun
// Build per-platform binaries and stage all npm packages into ./dist/npm/.
// Each subdirectory there is a publishable package.
//
// Layout produced:
//   dist/binaries/                          → raw compiled binaries
//   dist/npm/zonia/                         → unscoped launcher (Node, optionalDependencies)
//   dist/npm/@zonia-world/zonia-<plat>-<arch>/  → per-platform binary holder packages
//
// Usage:
//   bun scripts/prepare-npm.ts
//
// Then publish with scripts/publish-npm.sh.

import {
  chmodSync,
  copyFileSync,
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
const distBin = join(repoRoot, "dist", "binaries");
const clientDir = join(repoRoot, "client");

const SCOPE = "@zonia-world";
const HOMEPAGE = "https://github.com/jackharrhy/zonia";
const REPO_URL = "git+https://github.com/jackharrhy/zonia.git";
const BUGS_URL = "https://github.com/jackharrhy/zonia/issues";
const DEFAULT_SERVER = "wss://zonia.harrhy.xyz/socket";

interface Target {
  platform: "darwin" | "linux" | "win32";
  arch: "x64" | "arm64";
  bunTarget: string;
  exeSuffix?: string;
}

const TARGETS: Target[] = [
  { platform: "darwin", arch: "arm64", bunTarget: "bun-darwin-arm64" },
  { platform: "darwin", arch: "x64", bunTarget: "bun-darwin-x64" },
  { platform: "linux", arch: "x64", bunTarget: "bun-linux-x64" },
  { platform: "linux", arch: "arm64", bunTarget: "bun-linux-arm64" },
  { platform: "win32", arch: "x64", bunTarget: "bun-windows-x64", exeSuffix: ".exe" },
];

// Pull version from client/package.json so there's one source of truth.
const clientPkg = JSON.parse(
  readFileSync(join(clientDir, "package.json"), "utf8"),
) as { version?: string };
const VERSION = clientPkg.version ?? "0.1.0";

console.log(`Building zonia v${VERSION}`);
console.log(`Default server (baked in): ${DEFAULT_SERVER}`);

// ─── clean output ───────────────────────────────────────────────────────────
rmSync(distNpm, { recursive: true, force: true });
rmSync(distBin, { recursive: true, force: true });
mkdirSync(distNpm, { recursive: true });
mkdirSync(distBin, { recursive: true });

// ─── 0. ensure every target's @opentui/core-<plat>-<arch> is materialized ──
// `bun install` filters optionalDependencies by host platform by default, so
// cross-compilation needs the other platforms' native binaries explicitly
// installed via `bun install --os=... --cpu=...`. Idempotent.
console.log("Ensuring all opentui platform binaries are installed...");
for (const t of TARGETS) {
  const proc = Bun.spawnSync({
    cmd: ["bun", "install", `--os=${t.platform}`, `--cpu=${t.arch}`],
    cwd: clientDir,
    stdio: ["inherit", "pipe", "pipe"],
  });
  if (proc.exitCode !== 0) {
    console.error(`  ✗ failed to install for ${t.platform}-${t.arch}`);
    console.error(proc.stderr?.toString());
    process.exit(1);
  }
}

// ─── 1. compile per-platform binaries ──────────────────────────────────────
console.log("\nBuilding per-platform binaries...");
for (const t of TARGETS) {
  const exeName = `zonia-${t.platform}-${t.arch}${t.exeSuffix ?? ""}`;
  const outfile = join(distBin, exeName);
  console.log(`  → ${exeName}`);
  const proc = Bun.spawnSync({
    cmd: [
      "bun",
      "build",
      "--compile",
      `--target=${t.bunTarget}`,
      `--define=__ZONIA_BAKED_SERVER__=${JSON.stringify(DEFAULT_SERVER)}`,
      "src/index.ts",
      "--outfile",
      outfile,
    ],
    cwd: clientDir,
    stdio: ["inherit", "pipe", "pipe"],
  });
  if (proc.exitCode !== 0) {
    console.error(`  ✗ failed: ${exeName}`);
    console.error(proc.stderr?.toString());
    process.exit(1);
  }
}

// ─── 2. stage per-platform binary holder packages ──────────────────────────
console.log("\nStaging binary holder packages...");
for (const t of TARGETS) {
  const pkgName = `${SCOPE}/zonia-${t.platform}-${t.arch}`;
  const pkgDir = join(distNpm, "@zonia-world", `zonia-${t.platform}-${t.arch}`);
  const binDir = join(pkgDir, "bin");
  mkdirSync(binDir, { recursive: true });

  const exeName = `zonia-${t.platform}-${t.arch}${t.exeSuffix ?? ""}`;
  copyFileSync(join(distBin, exeName), join(binDir, exeName));
  if (!t.exeSuffix) chmodSync(join(binDir, exeName), 0o755);

  writeFileSync(
    join(pkgDir, "package.json"),
    JSON.stringify(
      {
        name: pkgName,
        version: VERSION,
        description: `Prebuilt zonia binary for ${t.platform}-${t.arch}`,
        license: "MIT",
        homepage: HOMEPAGE,
        repository: { type: "git", url: REPO_URL },
        files: ["bin/"],
        os: [t.platform],
        cpu: [t.arch],
      },
      null,
      2,
    ) + "\n",
  );

  writeFileSync(
    join(pkgDir, "README.md"),
    `# ${pkgName}

Prebuilt \`${t.platform}-${t.arch}\` binary for [zonia-world](https://www.npmjs.com/package/zonia-world).

You probably want the parent package instead:

\`\`\`sh
npx zonia-world
\`\`\`
`,
  );
  console.log(`  ✓ ${pkgName}`);
}

// ─── 3. stage the `zonia-world` launcher ───────────────────────────────────
console.log("\nStaging launcher package...");
{
  const pkgDir = join(distNpm, "zonia-world");
  mkdirSync(pkgDir, { recursive: true });

  const cliJs = `#!/usr/bin/env node
// zonia-world launcher: locate the platform-specific sub-package binary and exec it.

const { spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

const platform = process.platform;
const arch = process.arch;
const subPkg = \`@zonia-world/zonia-\${platform}-\${arch}\`;
const binaryName =
  platform === "win32"
    ? \`zonia-\${platform}-\${arch}.exe\`
    : \`zonia-\${platform}-\${arch}\`;

let binaryPath;
try {
  const subPkgJson = require.resolve(\`\${subPkg}/package.json\`);
  binaryPath = path.join(path.dirname(subPkgJson), "bin", binaryName);
} catch {}

if (!binaryPath || !fs.existsSync(binaryPath)) {
  process.stderr.write(
    \`\\nzonia-world: no prebuilt binary available for \${platform}-\${arch}.\\n\` +
      \`Supported: darwin-arm64, darwin-x64, linux-x64, linux-arm64, win32-x64.\\n\\n\`,
  );
  process.exit(1);
}

const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  windowsHide: false,
});
child.on("exit", (code, signal) =>
  signal ? process.kill(process.pid, signal) : process.exit(code ?? 0),
);
child.on("error", (err) => {
  process.stderr.write(\`zonia-world: failed to launch binary: \${err.message}\\n\`);
  process.exit(1);
});
`;
  writeFileSync(join(pkgDir, "cli.js"), cliJs);
  chmodSync(join(pkgDir, "cli.js"), 0o755);

  const optionalDeps: Record<string, string> = {};
  for (const t of TARGETS) {
    optionalDeps[`${SCOPE}/zonia-${t.platform}-${t.arch}`] = VERSION;
  }

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
        optionalDependencies: optionalDeps,
        engines: { node: ">=18" },
        os: ["darwin", "linux", "win32"],
        cpu: ["x64", "arm64"],
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

Pick a name on first run, and you're in. Names are unique, forever, and
local to your machine — lose your local data and the name is gone.

## Self-hosting

By default zonia-world connects to \`${DEFAULT_SERVER}\`. Override with:

\`\`\`sh
ZONIA_SERVER=ws://localhost:4000/socket npx zonia-world
\`\`\`

## Quit

\`ctrl-c\`.

## Source

${HOMEPAGE}
`,
  );
  console.log(`  ✓ zonia-world`);
}

console.log("\nDone. Packages staged in dist/npm/");
console.log("To publish:  ./scripts/publish-npm.sh");
