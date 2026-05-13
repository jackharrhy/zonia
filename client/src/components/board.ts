// Board renderer: paints a `{raw, style}` grid as a single styled
// TextRenderable and overlays per-player pawns as absolutely-positioned
// single-character renderables on top.
//
// The component owns its own subtree under `parent`. Call `update()` to
// re-render after a state change; the handle diffs board vs. pawns and
// only rebuilds what actually changed. `destroy()` detaches everything.

import {
  BoxRenderable,
  StyledText,
  TextRenderable,
  fg,
  type CliRenderer,
  type TextChunk,
} from "@opentui/core";
import { onThemeChange, pathColor, theme, type Tone } from "../lib/theme.js";

export interface BoardStyleEntry {
  kind:
    | "tile"
    | "edge_north"
    | "edge_south"
    | "edge_east"
    | "edge_west"
    | "decor";
  /** Server-side atom name, e.g. "cyan", "magenta", "green", "default". */
  color?: string;
  /** Present for some tiles, e.g. "minigame", "mystery", "star_shop". */
  effect?: string;
  start?: boolean;
}

export interface BoardData {
  name: string;
  raw: string;
  style: Record<string, BoardStyleEntry>;
  width: number;
  height: number;
  start: [number, number];
}

export interface BoardPlayer {
  user_id: number;
  name: string;
  /** [row, col] in grapheme coordinates. */
  pos: [number, number];
  /** 0..3 → maps to theme `pawn0`..`pawn3`. */
  color_slot: number;
}

export interface BoardHandle {
  /** Re-render after a state change. Diffs internally. */
  update(next: { board?: BoardData; players?: BoardPlayer[] }): void;
  /** Detach renderables from the parent and clean up listeners. */
  destroy(): void;
}

const PAWN_SLOTS: Tone[] = ["pawn0", "pawn1", "pawn2", "pawn3"];

function pawnTone(slot: number): Tone {
  const idx = ((slot % PAWN_SLOTS.length) + PAWN_SLOTS.length) %
    PAWN_SLOTS.length;
  // The modulo above keeps idx in [0, PAWN_SLOTS.length); the cast is safe.
  return PAWN_SLOTS[idx] as Tone;
}

function pawnChar(slot: number): string {
  return String(slot + 1);
}

const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

/**
 * Build the styled board text from `{raw, style}`. Every grapheme becomes
 * its own colored chunk; newlines become bare "\n" chunks to preserve
 * line breaks across the styled text.
 */
function buildBoardStyledText(board: BoardData): StyledText {
  const chunks: TextChunk[] = [];
  const lines = board.raw.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    for (const seg of segmenter.segment(line)) {
      const g = seg.segment;
      const entry = board.style[g];
      const color = pathColor(entry?.color);
      // `fg(color)(text)` returns a TextChunk; StyledText takes that array.
      chunks.push(fg(color)(g) as TextChunk);
    }
    if (i < lines.length - 1) {
      chunks.push({ __isChunk: true, text: "\n", attributes: 0 });
    }
  }
  return new StyledText(chunks);
}

interface PawnRenderable {
  player: BoardPlayer;
  text: TextRenderable;
}

export function mountBoard(
  renderer: CliRenderer,
  parent: BoxRenderable,
  board: BoardData,
  players: BoardPlayer[] = [],
): BoardHandle {
  // Container so positioning of pawns is relative to the board, not the
  // outer scene. Width/height match the board so absolute coords line up
  // with grapheme cells.
  const container = new BoxRenderable(renderer, {
    width: board.width,
    height: board.height,
    flexShrink: 0,
  });

  const boardText = new TextRenderable(renderer, {
    content: buildBoardStyledText(board),
  });
  container.add(boardText);

  const pawns = new Map<number, PawnRenderable>();

  const addPawn = (p: BoardPlayer): PawnRenderable => {
    const text = new TextRenderable(renderer, {
      content: pawnChar(p.color_slot),
      fg: theme.c[pawnTone(p.color_slot)],
      position: "absolute",
      top: p.pos[0],
      left: p.pos[1],
      zIndex: 10,
    });
    container.add(text);
    const pr = { player: p, text };
    pawns.set(p.user_id, pr);
    return pr;
  };

  for (const p of players) addPawn(p);

  parent.add(container);

  let currentBoard = board;

  const stopThemeWatch = onThemeChange(() => {
    // Path colors switch palette → rebuild the styled text from the same
    // board so cached chunks pick up the new hex codes.
    boardText.content = buildBoardStyledText(currentBoard);
    // Pawn fg's are bound via theme.c at construction, but theme.c is
    // a fresh object now — refresh each pawn's fg.
    for (const pr of pawns.values()) {
      pr.text.fg = theme.c[pawnTone(pr.player.color_slot)];
    }
  });

  return {
    update(next) {
      if (next.board && next.board !== currentBoard) {
        currentBoard = next.board;
        boardText.content = buildBoardStyledText(currentBoard);
        // Resize container if the board shape changed.
        container.width = currentBoard.width;
        container.height = currentBoard.height;
      }

      if (next.players) {
        const nextIds = new Set<number>();
        for (const p of next.players) {
          nextIds.add(p.user_id);
          const existing = pawns.get(p.user_id);
          if (!existing) {
            addPawn(p);
            continue;
          }
          // Diff against the prior snapshot: only touch what moved or
          // changed slot. Reassigning unchanged props would still flush
          // a render, so guard each setter.
          if (
            existing.player.pos[0] !== p.pos[0] ||
            existing.player.pos[1] !== p.pos[1]
          ) {
            existing.text.top = p.pos[0];
            existing.text.left = p.pos[1];
          }
          if (existing.player.color_slot !== p.color_slot) {
            existing.text.content = pawnChar(p.color_slot);
            existing.text.fg = theme.c[pawnTone(p.color_slot)];
          }
          existing.player = p;
        }
        // Remove pawns for players that left.
        for (const [id, pr] of pawns) {
          if (!nextIds.has(id)) {
            container.remove(pr.text.id);
            pawns.delete(id);
          }
        }
      }
    },

    destroy() {
      stopThemeWatch();
      // Removing the container takes care of all its children in one
      // shot. We don't need to remove() each pawn individually.
      parent.remove(container.id);
      pawns.clear();
    },
  };
}
