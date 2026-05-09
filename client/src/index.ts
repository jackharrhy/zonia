import { createCliRenderer } from "@opentui/core";
import { openIdentityStore } from "./lib/identity.js";
import { runRegisterScene } from "./scenes/register.js";
import { runChatScene } from "./scenes/chat.js";
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
  // Clicks should not steal focus from the active input. The chat and
  // register scenes both want their text field permanently focused.
  autoFocus: false,
});

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

runChatScene(renderer, identity);
