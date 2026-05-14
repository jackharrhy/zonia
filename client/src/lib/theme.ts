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
  | "self"
  /** Opaque background. Use on panels that sit next to the board so
   *  oversized boards don't bleed through into chat / players / hotbar. */
  | "bg"
  /** Per-player pawn colors. Four distinct hues, paired by slot. */
  | "pawn0"
  | "pawn1"
  | "pawn2"
  | "pawn3";

type Palette = Record<Tone, string>;

/**
 * Maps the server's color atom name (e.g. "cyan", "magenta", "green",
 * "default") to a hex color. Boards arrive with each character classed
 * by a color atom; the renderer looks the atom up here at paint time.
 *
 * Unknown atoms fall through to `default` so a server-side typo doesn't
 * crash the client — it just renders muted.
 */
type PathColors = Record<string, string>;

const darkPath: PathColors = {
  cyan: "#22d3ee", // bright teal — main path
  magenta: "#f472b6", // hot pink — minigame tiles
  yellow: "#fbbf24", // gold — stars, mystery
  green: "#22c55e", // forest — tree decor
  blue: "#3b82f6", // ocean — water decor
  gray: "#9ca3af", // stone — mountain decor
  red: "#ef4444",
  default: "#6b7280", // muted — empty space, fallback
};

const lightPath: PathColors = {
  cyan: "#0e7490",
  magenta: "#be185d",
  yellow: "#b45309",
  green: "#15803d",
  blue: "#1d4ed8",
  gray: "#4b5563",
  red: "#b91c1c",
  default: "#6b7280",
};

const dark: Palette = {
  fg: "#e5e7eb",
  muted: "#9ca3af",
  ok: "#10b981",
  warn: "#f59e0b",
  error: "#ef4444",
  self: "#60a5fa",
  // Near-black opaque fill. Painted over anything underneath (board
  // overflow). Slightly off-black so it's distinguishable from the
  // terminal's actual default background when needed.
  bg: "#0a0a0a",
  // Pawns — four distinct hues that read well on a colored board.
  pawn0: "#ef4444", // red
  pawn1: "#60a5fa", // blue
  pawn2: "#22c55e", // green
  pawn3: "#facc15", // yellow
};

const light: Palette = {
  fg: "#111827",
  muted: "#4b5563",
  ok: "#047857",
  warn: "#b45309",
  error: "#b91c1c",
  self: "#1d4ed8",
  // Near-white opaque fill for the same purpose.
  bg: "#fafafa",
  // Light-mode pawns: deeper for contrast on a brighter background.
  pawn0: "#b91c1c",
  pawn1: "#1d4ed8",
  pawn2: "#15803d",
  pawn3: "#a16207",
};

const palettes: Record<ThemeMode, Palette> = { dark, light };
const pathPalettes: Record<ThemeMode, PathColors> = {
  dark: darkPath,
  light: lightPath,
};

export const theme = {
  mode: "dark" as ThemeMode,
  c: dark,
  /**
   * Server-color-atom → hex for the active theme. Switches automatically
   * when the terminal theme changes. Use via `theme.path[atom] ??
   * theme.path.default`.
   */
  path: darkPath as PathColors,
};

type Listener = (mode: ThemeMode) => void;
const listeners: Listener[] = [];

function setMode(next: ThemeMode) {
  if (theme.mode === next) return;
  theme.mode = next;
  theme.c = palettes[next];
  theme.path = pathPalettes[next];
  for (const cb of listeners) cb(next);
}

export async function initTheme(
  renderer: CliRenderer,
  timeoutMs = 200,
): Promise<void> {
  const detected = await renderer.waitForThemeMode(timeoutMs);
  if (detected) setMode(detected);

  // Paint the entire render buffer in our `bg` tone. Without this the
  // renderer treats unset cells as transparent, which lets a board's
  // overflow leak into chrome that hasn't drawn its own background.
  renderer.setBackgroundColor(theme.c.bg);

  renderer.on(CliRenderEvents.THEME_MODE, (mode: ThemeMode) => {
    setMode(mode);
    renderer.setBackgroundColor(theme.c.bg);
  });
}

export function onThemeChange(cb: Listener): () => void {
  listeners.push(cb);
  return () => {
    const i = listeners.indexOf(cb);
    if (i >= 0) listeners.splice(i, 1);
  };
}

/**
 * Resolve a server-side color atom (e.g. "cyan", "default") to a hex
 * for the current theme. Convenience wrapper so consumers don't have to
 * remember the default-fallback dance.
 */
export function pathColor(atom: string | undefined): string {
  if (!atom) return theme.path.default ?? theme.c.muted;
  return theme.path[atom] ?? theme.path.default ?? theme.c.muted;
}
