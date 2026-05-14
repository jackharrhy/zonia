// Game scene: in-progress game view.
//
// Layout (step 3a is a husk — no game logic):
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ zonia · alice · round 1/8 · turn: —                          │  top bar
//   ├──────────────────────────────────────────────┬───────────────┤
//   │                                              │ players       │
//   │             [board, centered]                │ · alice ★0 ¢0 │
//   │                                              │ · bob   ★0 ¢0 │
//   │                                              ├───────────────┤
//   │                                              │ chat          │
//   │                                              │ > _           │
//   ├──────────────────────────────────────────────┴───────────────┤
//   │ hotbar: waiting for the game loop · [q] leave · [t] type     │
//   └──────────────────────────────────────────────────────────────┘
//
// Behavior summary:
//   - Joins `game:<code>` over an authenticated socket.
//   - Mounts the shared board component and a chat pane on first snapshot.
//   - Diffs subsequent snapshots into the board's `update({players})`.
//   - Renders an inline players panel (no reusable component yet).
//   - Hotkeys: `q` -> leave_game, `t` -> chat-typing mode, Esc -> back to hotkeys.
//   - Resolves with `{kind: "lobby"}` after `leave_game` succeeds or the
//     server pushes `game_ended`.

import {
  BoxRenderable,
  CliRenderEvents,
  TextRenderable,
  type CliRenderer,
  type Renderable,
} from "@opentui/core";
import type { Channel } from "phoenix";
import type { Identity } from "../lib/identity.js";
import { connectAuthed } from "../lib/socket.js";
import {
  mountBoard,
  type BoardData,
  type BoardHandle,
  type BoardPlayer,
} from "../components/board.js";
import { mountChatPane, type ChatPaneHandle } from "../components/chat-pane.js";
import { onThemeChange, theme, type Tone } from "../lib/theme.js";
import type { SceneResult } from "./types.js";

type Mode = "hotkeys" | "chat";

interface GamePlayer {
  user_id: number;
  name: string;
  pos: [number, number];
  stars: number;
  coins: number;
  color_slot: number;
  status: "active" | "disconnected";
}

interface GameSnapshot {
  code: string;
  board: BoardData;
  players: GamePlayer[];
  total_rounds: number;
  current_round: number;
  current_turn: { user_id: number; phase: string } | null;
  phase: string;
}

// The `snapshot` event from GameChannel wraps the snapshot in
// `{game: <snapshot>}`.
interface SnapshotEnvelope {
  game: GameSnapshot;
}

// Coerce a server `GamePlayer` into the `BoardPlayer` shape mountBoard wants.
// `color_slot` arrives as a number; BoardPlayer.color_slot is also `number`,
// but the board's pawnTone() does its own modulo so any int is fine.
function toBoardPlayer(p: GamePlayer): BoardPlayer {
  return {
    user_id: p.user_id,
    name: p.name,
    pos: p.pos,
    color_slot: p.color_slot,
  };
}

export function runGameScene(
  renderer: CliRenderer,
  identity: Identity,
  code: string,
): Promise<SceneResult> {
  return new Promise<SceneResult>((resolve) => {
    const { socket, ready, onStatusChange } = connectAuthed(identity.key);

    // ── layout ──────────────────────────────────────────────────────────
    const root = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });

    const topBar = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      backgroundColor: theme.c.bg,
      height: 3,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const topBarText = new TextRenderable(renderer, {
      content: `zonia · ${identity.name} · joining game ${code}…`,
      fg: theme.c.muted,
    });
    topBar.add(topBarText);

    const body = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "row",
    });

    // Left: a centered board.
    const boardCol = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      title: "board",
      titleAlignment: "left",
    });
    // mountBoard adds its own container to this slot.
    const boardSlot = new BoxRenderable(renderer, {
      flexDirection: "column",
      flexShrink: 0,
    });
    boardCol.add(boardSlot);

    // Right column: players panel on top, chat pane below.
    const rightCol = new BoxRenderable(renderer, {
      flexDirection: "column",
      width: 32,
    });

    const playersBox = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      backgroundColor: theme.c.bg,
      title: "players",
      titleAlignment: "left",
      height: 10,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const playersList = new BoxRenderable(renderer, {
      flexDirection: "column",
      flexGrow: 1,
    });
    playersBox.add(playersList);

    const chatBox = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      backgroundColor: theme.c.bg,
      title: "chat",
      titleAlignment: "left",
      flexGrow: 1,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "column",
    });
    const chatPaneHost = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });
    chatBox.add(chatPaneHost);

    rightCol.add(playersBox);
    rightCol.add(chatBox);

    body.add(boardCol);
    body.add(rightCol);

    const hotbar = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      backgroundColor: theme.c.bg,
      height: 3,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const hotbarText = new TextRenderable(renderer, {
      content: hotbarHints("hotkeys"),
      fg: theme.c.muted,
    });
    hotbar.add(hotbarText);

    root.add(topBar);
    root.add(body);
    root.add(hotbar);
    renderer.root.add(root);

    // ── state ───────────────────────────────────────────────────────────
    let mode: Mode = "hotkeys";
    let gameChannel: Channel | null = null;
    let chat: ChatPaneHandle | null = null;
    let boardHandle: BoardHandle | null = null;
    let snapshot: GameSnapshot | null = null;
    let topBarTone: Tone = "muted";
    let resolved = false;

    // ── teardown ────────────────────────────────────────────────────────
    const teardown = () => {
      if (resolved) return;
      resolved = true;

      try {
        chat?.destroy();
      } catch {
        // pane may already be detached
      }
      try {
        boardHandle?.destroy();
      } catch {
        // board may already be detached
      }

      stopThemeWatch();
      renderer.off(CliRenderEvents.FOCUSED_RENDERABLE, onFocusChange);
      renderer.keyInput.off("keypress", onKeypress);

      try {
        renderer.root.remove(root.id);
      } catch {
        // already gone
      }

      if (gameChannel) {
        try {
          gameChannel.leave();
        } catch {
          // best effort
        }
      }

      try {
        socket.disconnect();
      } catch {
        // best effort
      }
    };

    const finish = (result: SceneResult) => {
      teardown();
      resolve(result);
    };

    // ── rendering helpers ───────────────────────────────────────────────
    const setTopBar = (status: string, tone: Tone) => {
      topBarTone = tone;
      topBarText.content = topBarStatusText(status);
      topBarText.fg = theme.c[tone];
      topBar.borderColor = theme.c[tone];
    };

    const topBarStatusText = (status: string): string => {
      if (!snapshot) return `zonia · ${identity.name} · ${status}`;
      const round = `round ${snapshot.current_round}/${snapshot.total_rounds}`;
      const turn = snapshot.current_turn
        ? snapshot.current_turn.user_id.toString()
        : "—";
      return `zonia · ${identity.name} · ${round} · turn: ${turn} · ${status}`;
    };

    const renderPlayersPanel = () => {
      for (const child of playersList.getChildren()) {
        playersList.remove(child.id);
      }
      if (!snapshot) return;

      for (const p of snapshot.players) {
        const isMe = p.name === identity.name;
        const baseTone: Tone =
          p.status === "disconnected" ? "muted" : isMe ? "self" : "fg";
        const marker = p.status === "disconnected" ? " (offline)" : "";
        const line = new TextRenderable(renderer, {
          content: `· ${p.name} ★${p.stars} ¢${p.coins}${marker}`,
          fg: theme.c[baseTone],
        });
        playersList.add(line);
      }
    };

    let lastConnStatus = "connecting…";
    const refreshTopBar = () => {
      setTopBar(lastConnStatus, topBarTone);
    };

    // ── theme watch ─────────────────────────────────────────────────────
    const stopThemeWatch = onThemeChange(() => {
      refreshTopBar();
      topBar.borderColor = theme.c[topBarTone];
      boardCol.borderColor = theme.c.muted;
      playersBox.borderColor = theme.c.muted;
      chatBox.borderColor = theme.c.muted;
      hotbar.borderColor = theme.c.muted;
      hotbarText.fg = theme.c.muted;
      // Refresh occluding-panel backgrounds on theme flip so a board
      // overflowing into them doesn't peek through after dark↔light.
      topBar.backgroundColor = theme.c.bg;
      playersBox.backgroundColor = theme.c.bg;
      chatBox.backgroundColor = theme.c.bg;
      hotbar.backgroundColor = theme.c.bg;
      renderPlayersPanel();
    });

    // ── connection status ───────────────────────────────────────────────
    onStatusChange((s) => {
      if (resolved) return;
      if (s === "connected") {
        lastConnStatus = "connected";
        setTopBar(lastConnStatus, "ok");
      } else {
        lastConnStatus = "reconnecting…";
        setTopBar(lastConnStatus, "warn");
      }
    });

    // ── input handling ──────────────────────────────────────────────────
    const setMode = (next: Mode) => {
      mode = next;
      hotbarText.content = hotbarHints(mode);

      switch (mode) {
        case "hotkeys":
          chatBox.borderColor = theme.c.muted;
          // The focus-change handler below will blur whatever input is
          // focused next time the renderer emits a focus event. There's
          // no public blur helper on chat-pane, so we rely on that
          // mechanism rather than touching its input directly.
          break;
        case "chat":
          chatBox.borderColor = theme.c.self;
          if (chat) chat.focus();
          break;
      }
    };

    const onKeypress = (key: {
      name: string;
      ctrl: boolean;
      meta: boolean;
      preventDefault(): void;
      stopPropagation(): void;
    }) => {
      if (resolved) return;
      if (key.ctrl || key.meta) return;

      const consume = () => {
        key.preventDefault();
        key.stopPropagation();
      };

      if (mode !== "hotkeys") {
        if (key.name === "escape") {
          setMode("hotkeys");
          consume();
        }
        return;
      }

      switch (key.name) {
        case "q":
          leaveGame();
          consume();
          break;
        case "t":
          setMode("chat");
          consume();
          break;
      }
    };
    renderer.keyInput.on("keypress", onKeypress);

    const onFocusChange = (focused: Renderable | null) => {
      if (resolved) return;
      switch (mode) {
        case "chat":
          // chat-pane owns its own input; nothing to do.
          break;
        case "hotkeys":
          if (focused) {
            (focused as unknown as { blur?: () => void }).blur?.();
          }
          break;
      }
    };
    renderer.on(CliRenderEvents.FOCUSED_RENDERABLE, onFocusChange);

    // ── actions ─────────────────────────────────────────────────────────
    const leaveGame = () => {
      if (!gameChannel) {
        finish({ kind: "lobby" });
        return;
      }
      gameChannel
        .push("leave_game", {})
        .receive("ok", () => {
          finish({ kind: "lobby" });
        })
        .receive("error", (resp: { reason?: string }) => {
          chat?.appendSystem(
            `* could not leave: ${resp?.reason ?? "unknown"}`,
            "error",
          );
        });
    };

    // ── snapshot handling ───────────────────────────────────────────────
    const applySnapshot = (next: GameSnapshot) => {
      const isFirst = snapshot === null;
      snapshot = next;

      if (isFirst) {
        boardHandle = mountBoard(
          renderer,
          boardSlot,
          next.board,
          next.players.map(toBoardPlayer),
        );
        if (gameChannel) {
          chat = mountChatPane(renderer, chatPaneHost, {
            channel: gameChannel,
            selfName: identity.name,
          });
          chat.appendSystem(`* entered game ${next.code}`, "ok");
        }
      } else if (boardHandle) {
        boardHandle.update({ players: next.players.map(toBoardPlayer) });
      }

      renderPlayersPanel();
      refreshTopBar();
    };

    // ── channel wiring ──────────────────────────────────────────────────
    ready
      .then(() => {
        const channel = socket.channel(`game:${code}`, {});
        gameChannel = channel;

        channel.on("snapshot", (payload: SnapshotEnvelope) => {
          applySnapshot(payload.game);
        });

        channel.on("game_ended", () => {
          chat?.appendSystem("* game ended", "warn");
          finish({ kind: "lobby" });
        });

        // `say` events are owned by the chat pane (it listens on the same
        // channel). presence_state / presence_diff are accepted but not
        // surfaced in step 3a — the players panel uses snapshot.status
        // instead.

        channel
          .join()
          .receive("ok", () => {
            lastConnStatus = "connected";
            setTopBar(lastConnStatus, "ok");
          })
          .receive("error", (resp: { reason?: string }) => {
            const reason = resp?.reason ?? "unknown";
            setTopBar(`game join failed: ${reason}`, "error");
            // If we're not actually a member of this game, kick back to
            // the lobby — staying here is useless.
            if (reason === "not_in_game") {
              finish({ kind: "lobby" });
            }
          });
      })
      .catch((err: Error) => {
        if (err.message === "auth_rejected") {
          setTopBar("auth rejected — clear local data and re-enter", "error");
        } else {
          setTopBar(`connection failed: ${err.message}`, "error");
        }
      });
  });
}

function hotbarHints(mode: Mode): string {
  switch (mode) {
    case "hotkeys":
      return " waiting for the game loop · [q] leave · [t] type";
    case "chat":
      return " typing — esc to return to hotkeys";
  }
}
