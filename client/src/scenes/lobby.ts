// Lobby scene. Where players gather after registration. Lists open rooms,
// lets you create one or join someone else's by code, and (eventually)
// transitions into a game when the host starts it.
//
// Layout:
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ zonia · alice                                                    │  ← top bar
//   ├──────────────────────────┬───────────────────────────────────────┤
//   │ rooms                    │ chat                                  │
//   │  · BX7Q (alice)  1/4     │  [12:30] alice: hi                    │
//   │  · MK9P (bob)    2/4     │  [12:30] bob: yo                      │
//   │                          │                                       │
//   │ your room: BX7Q          │                                       │
//   │  · alice (host)          │                                       │
//   │  · bob                   │                                       │
//   │                          │ > _                                   │
//   ├──────────────────────────┴───────────────────────────────────────┤
//   │ [c]reate  [j]oin  [s]tart  [l]eave  [t]ype                       │  ← footer
//   └──────────────────────────────────────────────────────────────────┘
//
// Step 2 wires every interaction except `start_game`, which the server
// stubs out. Step 3 will hand off into the game scene when start succeeds.

import {
  BoxRenderable,
  CliRenderEvents,
  InputRenderable,
  InputRenderableEvents,
  ScrollBoxRenderable,
  TextRenderable,
  type CliRenderer,
  type Renderable,
} from "@opentui/core";
import type { Channel } from "phoenix";
import type { Identity } from "../lib/identity.js";
import { connectAuthed } from "../lib/socket.js";
import { mountChatPane, type ChatPaneHandle } from "../components/chat-pane.js";
import { onThemeChange, theme, type Tone } from "../lib/theme.js";

// Mode for the focused input. Lobby is keyboard-driven: hotkeys for
// actions, but `t` and `j` switch focus into a prompt that reads a line
// of input (chat text or a room code).
type Mode = "hotkeys" | "chat" | "join_code";

interface RoomSummary {
  code: string;
  host_user_id: number;
  players: Array<{ user_id: number; name: string }>;
  board: string;
  total_rounds: number;
  max_players: number;
}

interface RoomsPayload {
  rooms: RoomSummary[];
}

export function runLobbyScene(
  renderer: CliRenderer,
  identity: Identity,
): Promise<void> {
  return new Promise<void>((resolve) => {
    // ── socket + lobby channel ──────────────────────────────────────────
    const { socket, ready, onStatusChange } = connectAuthed(identity.key);

    // ── layout ──────────────────────────────────────────────────────────
    const root = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });

    const topBar = new TextRenderable(renderer, {
      content: ` zonia · ${identity.name} · connecting…`,
      fg: theme.c.muted,
    });

    const body = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "row",
    });

    // Left column — rooms list + your current room.
    const leftCol = new BoxRenderable(renderer, {
      flexDirection: "column",
      width: 36,
      paddingLeft: 1,
      paddingRight: 1,
    });

    const roomsHeader = new TextRenderable(renderer, {
      content: " rooms",
      fg: theme.c.muted,
    });
    const roomsList = new ScrollBoxRenderable(renderer, {
      flexGrow: 1,
      contentOptions: { flexDirection: "column" },
    });
    const youAreInHeader = new TextRenderable(renderer, {
      content: " ",
      fg: theme.c.muted,
    });
    const youAreInList = new BoxRenderable(renderer, {
      flexDirection: "column",
      height: 6,
    });

    leftCol.add(roomsHeader);
    leftCol.add(roomsList);
    leftCol.add(youAreInHeader);
    leftCol.add(youAreInList);

    // Right column — chat pane.
    const rightCol = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
      paddingLeft: 1,
      paddingRight: 1,
    });
    const chatHeader = new TextRenderable(renderer, {
      content: " chat",
      fg: theme.c.muted,
    });
    rightCol.add(chatHeader);
    const chatPaneHost = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });
    rightCol.add(chatPaneHost);

    body.add(leftCol);
    body.add(rightCol);

    // Prompt for hotkey-driven inputs (`j` for join code, `t` not strictly
    // needed since chat-pane has its own input — see input routing below).
    const promptLabel = new TextRenderable(renderer, {
      content: " ",
      fg: theme.c.muted,
    });
    const promptInput = new InputRenderable(renderer, {
      placeholder: "",
      maxLength: 24,
      width: "100%",
    });

    const footer = new TextRenderable(renderer, {
      content: footerHints("hotkeys"),
      fg: theme.c.muted,
    });

    root.add(topBar);
    root.add(body);
    root.add(promptLabel);
    root.add(promptInput);
    root.add(footer);
    renderer.root.add(root);

    // ── state ───────────────────────────────────────────────────────────
    let mode: Mode = "hotkeys";
    let lobbyChannel: Channel | null = null;
    let chat: ChatPaneHandle | null = null;
    let rooms: RoomSummary[] = [];
    let myRoomCode: string | null = null;
    let topBarTone: Tone = "muted";

    const setTopBar = (status: string, tone: Tone) => {
      topBarTone = tone;
      topBar.content = ` zonia · ${identity.name} · ${status}`;
      topBar.fg = theme.c[tone];
    };

    const setMode = (next: Mode) => {
      mode = next;
      footer.content = footerHints(mode);

      switch (mode) {
        case "hotkeys":
          promptLabel.content = " ";
          promptInput.placeholder = "";
          promptInput.value = "";
          promptInput.blur();
          break;
        case "join_code":
          promptLabel.content = " join room code:";
          promptLabel.fg = theme.c.muted;
          promptInput.placeholder = "4-char code, e.g. BX7Q";
          promptInput.value = "";
          promptInput.focus();
          break;
        case "chat":
          promptLabel.content = " ";
          promptInput.placeholder = "";
          promptInput.value = "";
          promptInput.blur();
          if (chat) chat.focus();
          break;
      }
    };

    // ── rendering helpers ───────────────────────────────────────────────
    const renderRoomsList = () => {
      // Clear existing children.
      for (const child of roomsList.getChildren()) {
        roomsList.remove(child.id);
      }
      if (rooms.length === 0) {
        const line = new TextRenderable(renderer, {
          content: "  (no open rooms — press c to create one)",
          fg: theme.c.muted,
        });
        roomsList.add(line);
        return;
      }
      for (const r of rooms) {
        const host = r.players.find((p) => p.user_id === r.host_user_id);
        const hostName = host?.name ?? "?";
        const tone: Tone = r.code === myRoomCode ? "ok" : "fg";
        const line = new TextRenderable(renderer, {
          content: `  · ${r.code} (${hostName}) ${r.players.length}/${r.max_players}`,
          fg: theme.c[tone],
        });
        roomsList.add(line);
      }
    };

    const renderYouAreIn = () => {
      // Clear.
      for (const child of youAreInList.getChildren()) {
        youAreInList.remove(child.id);
      }

      if (!myRoomCode) {
        youAreInHeader.content = " you're in: (no room)";
        return;
      }

      const room = rooms.find((r) => r.code === myRoomCode);
      if (!room) {
        // Room vanished from the listing (e.g., host left). Clear our state.
        myRoomCode = null;
        youAreInHeader.content = " you're in: (room closed)";
        youAreInHeader.fg = theme.c.warn;
        return;
      }

      youAreInHeader.content = ` you're in: ${room.code}`;
      youAreInHeader.fg = theme.c.ok;

      for (const p of room.players) {
        const isHost = p.user_id === room.host_user_id;
        const isMine = isMe(p);
        const label = `   · ${p.name}${isHost ? " (host)" : ""}${isMine ? " ← you" : ""}`;
        const tone: Tone = isMine ? "self" : "fg";
        const line = new TextRenderable(renderer, {
          content: label,
          fg: theme.c[tone],
        });
        youAreInList.add(line);
      }
    };

    // We don't know our numeric user_id client-side — identity only has
    // {name, key}. Names are unique-forever, so matching on name is
    // safe.
    const isMe = (player: { name: string }) => player.name === identity.name;

    const renderEverything = () => {
      renderRoomsList();
      renderYouAreIn();
    };

    // ── theme reactivity ────────────────────────────────────────────────
    const stopThemeWatch = onThemeChange(() => {
      setTopBar(topBarStatus(), topBarTone);
      roomsHeader.fg = theme.c.muted;
      chatHeader.fg = theme.c.muted;
      footer.fg = theme.c.muted;
      renderEverything();
    });

    let lastStatus = "connecting…";
    const topBarStatus = () => lastStatus;

    onStatusChange((s) => {
      if (s === "connected") {
        lastStatus = "connected";
        setTopBar(lastStatus, "ok");
      } else {
        lastStatus = "reconnecting…";
        setTopBar(lastStatus, "warn");
      }
    });

    // ── keyboard routing ────────────────────────────────────────────────
    // Hotkeys only fire when in "hotkeys" mode. In other modes, the
    // focused input takes the keystrokes; we still listen for `escape`
    // to bail back to hotkey mode.
    const onKeypress = (key: { name: string; ctrl: boolean }) => {
      if (mode !== "hotkeys") {
        if (key.name === "escape") setMode("hotkeys");
        return;
      }
      switch (key.name) {
        case "c":
          createRoom();
          break;
        case "j":
          if (!myRoomCode) setMode("join_code");
          break;
        case "s":
          if (myRoomCode) startGame();
          break;
        case "l":
          if (myRoomCode) leaveRoom();
          break;
        case "t":
          setMode("chat");
          break;
      }
    };
    renderer.keyInput.on("keypress", onKeypress);

    // Pin focus appropriately. In hotkeys mode nothing is focused; in
    // chat mode the chat input owns it; in join_code mode the prompt
    // input owns it. We let OpenTUI's clicks bounce against this so
    // accidental clicks don't strand the user with no focused input.
    const onFocusChange = (focused: Renderable | null) => {
      switch (mode) {
        case "join_code":
          if (focused !== promptInput) promptInput.focus();
          break;
        case "chat":
          // chat pane owns its own input; leave focus alone.
          break;
        case "hotkeys":
          if (focused) (focused as unknown as { blur?: () => void }).blur?.();
          break;
      }
    };
    renderer.on(CliRenderEvents.FOCUSED_RENDERABLE, onFocusChange);

    // Join-code input: submit on Enter, send join_room.
    promptInput.on(InputRenderableEvents.ENTER, (raw: string) => {
      if (mode !== "join_code") return;
      const code = raw.trim().toUpperCase();
      if (code === "") return;
      void joinRoom(code);
    });

    // ── lobby actions ───────────────────────────────────────────────────
    const createRoom = () => {
      if (!lobbyChannel) return;
      lobbyChannel
        .push("create_room", {})
        .receive("ok", (resp: { room: RoomSummary }) => {
          myRoomCode = resp.room.code;
          chat?.appendSystem(`* you created room ${resp.room.code}`, "ok");
        })
        .receive("error", (resp: { reason?: string }) => {
          chat?.appendSystem(
            `* could not create room: ${resp?.reason ?? "unknown"}`,
            "error",
          );
        });
    };

    const joinRoom = (code: string) => {
      if (!lobbyChannel) return;
      lobbyChannel
        .push("join_room", { code })
        .receive("ok", (resp: { room: RoomSummary }) => {
          myRoomCode = resp.room.code;
          chat?.appendSystem(`* you joined room ${resp.room.code}`, "ok");
          setMode("hotkeys");
        })
        .receive("error", (resp: { reason?: string }) => {
          chat?.appendSystem(
            `* could not join: ${resp?.reason ?? "unknown"}`,
            "error",
          );
          // Stay in join_code mode so the user can retry.
          promptInput.value = "";
        });
    };

    const leaveRoom = () => {
      if (!lobbyChannel || !myRoomCode) return;
      const code = myRoomCode;
      lobbyChannel
        .push("leave_room", { code })
        .receive("ok", () => {
          myRoomCode = null;
          chat?.appendSystem(`* you left room ${code}`, "muted");
        })
        .receive("error", (resp: { reason?: string }) => {
          chat?.appendSystem(
            `* could not leave: ${resp?.reason ?? "unknown"}`,
            "error",
          );
        });
    };

    const startGame = () => {
      if (!lobbyChannel || !myRoomCode) return;
      const code = myRoomCode;
      lobbyChannel
        .push("start_game", { code })
        .receive("ok", (resp: { message?: string }) => {
          // Step 2: server returns a stub message. Step 3 will broadcast
          // a `game_started` event we'll catch and transition on.
          myRoomCode = null;
          chat?.appendSystem(
            `* game ${code} started (${resp?.message ?? "ok"})`,
            "ok",
          );
        })
        .receive("error", (resp: { reason?: string }) => {
          chat?.appendSystem(
            `* could not start: ${resp?.reason ?? "unknown"}`,
            "error",
          );
        });
    };

    // ── boot ────────────────────────────────────────────────────────────
    ready
      .then(() => {
        const channel = socket.channel("lobby:main", {});
        lobbyChannel = channel;

        channel.on("rooms", (payload: RoomsPayload) => {
          rooms = payload.rooms;

          // If our room disappeared from the listing (e.g. host left or
          // someone else's start succeeded), reflect that.
          if (myRoomCode && !rooms.some((r) => r.code === myRoomCode)) {
            chat?.appendSystem(
              `* room ${myRoomCode} closed`,
              "warn",
            );
            myRoomCode = null;
          }

          // If the lobby tells us about a room we believe we're in but
          // we're no longer listed in its players, drop our state.
          if (myRoomCode) {
            const room = rooms.find((r) => r.code === myRoomCode);
            if (room && !room.players.some(isMe)) {
              myRoomCode = null;
            }
          }

          renderEverything();
        });

        channel
          .join()
          .receive("ok", () => {
            chat = mountChatPane(renderer, chatPaneHost, {
              channel,
              selfName: identity.name,
            });
            chat.appendSystem(
              `* entered the lobby as ${identity.name}`,
              "ok",
            );
            setMode("hotkeys");
            renderEverything();
          })
          .receive("error", (resp: { reason?: string }) => {
            setTopBar(`lobby join failed: ${resp?.reason ?? "unknown"}`, "error");
          });
      })
      .catch((err: Error) => {
        if (err.message === "auth_rejected") {
          setTopBar(
            "auth rejected — clear local data and re-enter",
            "error",
          );
        } else {
          setTopBar(`connection failed: ${err.message}`, "error");
        }
      });

    // ── teardown ────────────────────────────────────────────────────────
    // Step 2 doesn't actually transition out of the lobby on game start
    // (the server stub doesn't kick us). For now the lobby scene never
    // resolves; the user quits via Ctrl-C.
    //
    // When step 3 lands a `game_started` event, this is where we'd:
    //   chat?.destroy(); stopThemeWatch(); renderer.root.remove(root.id);
    //   renderer.off(CliRenderEvents.FOCUSED_RENDERABLE, onFocusChange);
    //   renderer.keyInput.off("keypress", onKeypress);
    //   renderer.keyInput.off("keypress", onKeypressGlobal);
    //   resolve();
    void stopThemeWatch;
    void resolve;
  });
}

function footerHints(mode: Mode): string {
  switch (mode) {
    case "hotkeys":
      return " [c]reate  [j]oin  [s]tart  [l]eave  [t]ype  ·  ctrl-c to quit";
    case "join_code":
      return " enter the 4-char room code, esc to cancel";
    case "chat":
      return " typing — esc to return to hotkeys";
  }
}
