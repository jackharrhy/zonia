// Preview scene: load a board fixture JSON from disk and render it with
// no players. Used by `just preview-board <name>` to iterate on art and
// the parser without standing up the full server.

import {
  BoxRenderable,
  TextRenderable,
  type CliRenderer,
} from "@opentui/core";
import { mountBoard, type BoardData } from "../components/board.js";
import { onThemeChange, theme } from "../lib/theme.js";

export async function runPreviewScene(
  renderer: CliRenderer,
  fixturePath: string,
): Promise<void> {
  const board = (await Bun.file(fixturePath).json()) as BoardData;

  const root = new BoxRenderable(renderer, {
    flexGrow: 1,
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: 1,
  });

  const header = new TextRenderable(renderer, {
    content: ` ${board.name}  ${board.width}×${board.height} `,
    fg: theme.c.fg,
  });

  const footer = new TextRenderable(renderer, {
    content: "press q or ctrl-c to quit",
    fg: theme.c.muted,
  });

  root.add(header);

  // Wrap the board so the column layout doesn't try to stretch it.
  const boardWrap = new BoxRenderable(renderer, {
    flexShrink: 0,
  });
  root.add(boardWrap);
  root.add(footer);
  renderer.root.add(root);

  mountBoard(renderer, boardWrap, board);

  const stopThemeWatch = onThemeChange(() => {
    header.fg = theme.c.fg;
    footer.fg = theme.c.muted;
  });

  await new Promise<void>((resolve) => {
    const onKey = (key: { name: string; ctrl: boolean }) => {
      if (key.name === "q" || (key.ctrl && key.name === "c")) {
        renderer.keyInput.off("keypress", onKey);
        stopThemeWatch();
        renderer.destroy();
        resolve();
      }
    };
    renderer.keyInput.on("keypress", onKey);
  });
}
