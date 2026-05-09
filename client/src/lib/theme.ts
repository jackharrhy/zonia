import {
  CliRenderEvents,
  type CliRenderer,
  type ThemeMode,
} from "@opentui/core";

export type Tone =
  /** Default body / primary chat text. */
  | "fg"
  /** Quieter text: labels, prompts, "* x entered" system lines. */
  | "muted"
  /** "Connected", success, your-own-name highlight. */
  | "ok"
  /** Reconnecting, name-validation hint while typing. */
  | "warn"
  /** Auth rejected, message rejected, hard errors. */
  | "error"
  /** Your own messages: distinguish from other speakers. */
  | "self";

type Palette = Record<Tone, string>;

const dark: Palette = {
  fg: "#e5e7eb",
  muted: "#9ca3af",
  ok: "#10b981",
  warn: "#f59e0b",
  error: "#ef4444",
  self: "#60a5fa",
};

const light: Palette = {
  fg: "#111827",
  muted: "#4b5563",
  ok: "#047857",
  warn: "#b45309",
  error: "#b91c1c",
  self: "#1d4ed8",
};

const palettes: Record<ThemeMode, Palette> = { dark, light };

export const theme = {
  mode: "dark" as ThemeMode,
  c: dark,
};

type Listener = (mode: ThemeMode) => void;
const listeners: Listener[] = [];

function setMode(next: ThemeMode) {
  if (theme.mode === next) return;
  theme.mode = next;
  theme.c = palettes[next];
  for (const cb of listeners) cb(next);
}

export async function initTheme(
  renderer: CliRenderer,
  timeoutMs = 200,
): Promise<void> {
  const detected = await renderer.waitForThemeMode(timeoutMs);
  if (detected) setMode(detected);

  renderer.on(CliRenderEvents.THEME_MODE, (mode: ThemeMode) => {
    setMode(mode);
  });
}

export function onThemeChange(cb: Listener): () => void {
  listeners.push(cb);
  return () => {
    const i = listeners.indexOf(cb);
    if (i >= 0) listeners.splice(i, 1);
  };
}
