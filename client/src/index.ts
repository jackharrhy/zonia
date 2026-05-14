import { createCliRenderer } from "@opentui/core";
import { openIdentityStore } from "./lib/identity.js";
import { initTheme } from "./lib/theme.js";
import { runRegisterScene } from "./scenes/register.js";
import { runLobbyScene } from "./scenes/lobby.js";
import { runGameScene } from "./scenes/game.js";
import type { SceneResult } from "./scenes/types.js";
import { registerName } from "./lib/socket.js";

// Parse a single --name flag from argv. Used by `just client <name>` to
// auto-register without going through the prompt.
function parseNameFlag(argv: string[]): string | null {
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--name" && i + 1 < argv.length) return argv[i + 1] ?? null;
    if (arg && arg.startsWith("--name=")) return arg.slice("--name=".length);
  }
  return null;
}

const AUTO_ERROR_MESSAGES: Record<string, string> = {
  name_invalid: "auto: name must be 2–24 chars, letters/numbers/_/-",
  name_reserved: "auto: that name is reserved",
  name_taken: "auto: name is taken",
  join_failed: "auto: could not reach the void",
  timeout: "auto: server timed out",
};

const renderer = await createCliRenderer({
  exitOnCtrlC: true,
  consoleMode: "console-overlay",
  openConsoleOnError: true,
  // Clicks should not steal focus from the active input. The register
  // and lobby scenes manage focus themselves based on the current mode.
  autoFocus: false,
});

// Pick a palette before anything paints. Blocks briefly for the terminal's
// theme reply; falls through to the dark default if the terminal is silent.
await initTheme(renderer);

const store = openIdentityStore();
let identity = store.load();

if (!identity) {
  const cliName = parseNameFlag(process.argv.slice(2));

  let auto: { name: string; key: string } | null = null;
  let autoError: string | undefined;

  if (cliName) {
    const result = await registerName(cliName);
    if (result.ok) {
      auto = result.result;
    } else {
      autoError =
        AUTO_ERROR_MESSAGES[result.reason] ?? `auto: ${result.reason}`;
    }
  }

  if (auto) {
    store.save({ name: auto.name, key: auto.key });
    identity = { ...auto, createdAt: new Date().toISOString() };
  } else {
    const fresh = await runRegisterScene(renderer, store, {
      initialValue: cliName ?? "",
      initialError: autoError,
    });
    identity = { ...fresh, createdAt: new Date().toISOString() };
  }
}

// Scene loop: bounce between lobby and game until the process exits
// (Ctrl-C, handled by the renderer's exitOnCtrlC).
let next: SceneResult = { kind: "lobby" };
while (true) {
  if (next.kind === "lobby") {
    next = await runLobbyScene(renderer, identity);
  } else {
    next = await runGameScene(renderer, identity, next.code);
  }
}
