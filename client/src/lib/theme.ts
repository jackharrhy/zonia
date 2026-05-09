// Single source of truth for every color in the UI.
//
// We keep two palettes — `dark` and `light` — keyed by semantic role rather
// than by raw hex code. The active palette is chosen from the terminal's
// reported theme via OpenTUI's themeMode detection (DEC 2031 / OSC 10/11).
// We default to dark on first paint, then swap if/when the terminal reports
// otherwise.
//
// All scenes import `theme` and resolve colors through it. To restyle the
// app, edit the palettes here.

import {
  CliRenderEvents,
  type CliRenderer,
  type ThemeMode,
} from "@opentui/core";

export type Tone =
  /** Default body / primary chat text. */
  | "fg"
  /** Quieter text — labels, prompts, "* x entered" system lines. */
  | "muted"
  /** "Connected", success, your-own-name highlight. */
  | "ok"
  /** Reconnecting, name-validation hint while typing. */
  | "warn"
  /** Auth rejected, message rejected, hard errors. */
  | "error"
  /** Your own messages — distinguish from other speakers. */
  | "self";

type Palette = Record<Tone, string>;

// Tailwind-derived swatches, one per tone, picked for legibility on a black
// or near-black background.
const dark: Palette = {
  fg: "#e5e7eb",
  muted: "#9ca3af",
  ok: "#10b981",
  warn: "#f59e0b",
  error: "#ef4444",
  self: "#60a5fa",
};

// Light-mode equivalents. Same hue family, deeper saturation so they're
// readable on a white-ish background. `fg` becomes near-black.
const light: Palette = {
  fg: "#111827",
  muted: "#4b5563",
  ok: "#047857",
  warn: "#b45309",
  error: "#b91c1c",
  self: "#1d4ed8",
};

const palettes: Record<ThemeMode, Palette> = { dark, light };

/**
 * The active theme. Mutates in place when the terminal swaps modes; scenes
 * subscribe via `onThemeChange` to repaint affected renderables.
 */
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

/**
 * Resolve the active palette + subscribe to theme_mode changes from the
 * renderer. Call once at boot, before any scene mounts.
 *
 * We block briefly (default 200ms) for the terminal's reply to OpenTUI's
 * theme query so the very first paint already uses the right palette
 * instead of flashing dark-then-light.
 */
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

/**
 * Register a callback that fires whenever the active theme changes. The
 * callback receives the new mode; resolve `theme.c` inside it for fresh
 * colors.
 */
export function onThemeChange(cb: Listener): () => void {
  listeners.push(cb);
  return () => {
    const i = listeners.indexOf(cb);
    if (i >= 0) listeners.splice(i, 1);
  };
}
