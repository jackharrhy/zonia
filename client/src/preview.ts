// Entry point for the standalone board preview. Run via
// `bun run --watch src/preview.ts -- --fixture <path>`; the `just
// preview-board` recipe wraps this. Default fixture is the dump that
// `mix zonia.dump_board zonia-isle` writes to ../tmp/boards/.

import path from "node:path";
import { createCliRenderer } from "@opentui/core";
import { initTheme } from "./lib/theme.js";
import { runPreviewScene } from "./scenes/preview-board.js";

function parseFixtureFlag(argv: string[]): string | null {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--fixture" && i + 1 < argv.length) return argv[i + 1] ?? null;
    if (arg && arg.startsWith("--fixture="))
      return arg.slice("--fixture=".length);
  }
  return null;
}

const argv = process.argv.slice(2);
const flag = parseFixtureFlag(argv);
// Default resolves relative to the client's cwd (typically `client/`),
// pointing at `../tmp/boards/zonia-isle.json` at the repo root.
const fixturePath = flag
  ? path.resolve(process.cwd(), flag)
  : path.resolve(process.cwd(), "..", "tmp", "boards", "zonia-isle.json");

const renderer = await createCliRenderer({
  exitOnCtrlC: true,
  consoleMode: "console-overlay",
  openConsoleOnError: true,
  autoFocus: false,
});

await initTheme(renderer);

await runPreviewScene(renderer, fixturePath);
