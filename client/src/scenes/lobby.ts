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
    const { socket, ready, onStatusChange } = connectAuthed(identity.key);

    const root = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });

    const topBar = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      height: 3,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const topBarText = new TextRenderable(renderer, {
      content: `zonia · ${identity.name} · connecting…`,
      fg: theme.c.muted,
    });
    topBar.add(topBarText);

    const body = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "row",
    });

    const leftCol = new BoxRenderable(renderer, {
      flexDirection: "column",
      width: 38,
    });

    const roomsBox = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      title: "rooms",
      titleAlignment: "left",
      flexGrow: 1,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const roomsList = new ScrollBoxRenderable(renderer, {
      flexGrow: 1,
      contentOptions: { flexDirection: "column" },
    });
    roomsBox.add(roomsList);

    const yourRoomBox = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      title: "your room",
      titleAlignment: "left",
      height: 8,
      paddingLeft: 1,
      paddingRight: 1,
    });
    const yourRoomList = new BoxRenderable(renderer, {
      flexDirection: "column",
      flexGrow: 1,
    });
    yourRoomBox.add(yourRoomList);

    leftCol.add(roomsBox);
    leftCol.add(yourRoomBox);

    const rightCol = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      title: "chat",
      titleAlignment: "left",
      paddingLeft: 1,
      paddingRight: 1,
    });
    const chatPaneHost = new BoxRenderable(renderer, {
      flexGrow: 1,
      flexDirection: "column",
    });
    rightCol.add(chatPaneHost);

    body.add(leftCol);
    body.add(rightCol);

    const promptBox = new BoxRenderable(renderer, {
      border: true,
      borderStyle: "rounded",
      borderColor: theme.c.muted,
      height: 3,
      paddingLeft: 1,
      paddingRight: 1,
      flexDirection: "row",
    });
    const promptLabel = new TextRenderable(renderer, {
      content: "",
      fg: theme.c.muted,
    });
    const promptInput = new InputRenderable(renderer, {
      placeholder: "",
      maxLength: 24,
      width: "100%",
    });
    promptBox.add(promptLabel);
    promptBox.add(promptInput);

    const footer = new TextRenderable(renderer, {
      content: footerHints("hotkeys"),
      fg: theme.c.muted,
    });

    root.add(topBar);
    root.add(body);
    root.add(promptBox);
    root.add(footer);
    renderer.root.add(root);

    let mode: Mode = "hotkeys";
    let lobbyChannel: Channel | null = null;
    let chat: ChatPaneHandle | null = null;
    let rooms: RoomSummary[] = [];
    let myRoomCode: string | null = null;
    let topBarTone: Tone = "muted";

    const setTopBar = (status: string, tone: Tone) => {
      topBarTone = tone;
      topBarText.content = `zonia · ${identity.name} · ${status}`;
      topBarText.fg = theme.c[tone];
      topBar.borderColor = theme.c[tone];
    };

    const setMode = (next: Mode) => {
      mode = next;
      footer.content = footerHints(mode);

      switch (mode) {
        case "hotkeys":
          promptLabel.content = "";
          promptInput.placeholder = "";
          promptInput.value = "";
          promptInput.blur();
          promptBox.borderColor = theme.c.muted;
          break;
        case "join_code":
          promptLabel.content = "join code › ";
          promptLabel.fg = theme.c.warn;
          promptInput.placeholder = "4-char code, e.g. BX7Q";
          promptInput.value = "";
          promptInput.focus();
          promptBox.borderColor = theme.c.warn;
          break;
        case "chat":
          promptLabel.content = "";
          promptInput.placeholder = "";
          promptInput.value = "";
          promptInput.blur();
          promptBox.borderColor = theme.c.self;
          if (chat) chat.focus();
          break;
      }
    };

    const renderRoomsList = () => {
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

    const renderYourRoom = () => {
      for (const child of yourRoomList.getChildren()) {
        yourRoomList.remove(child.id);
      }

      if (!myRoomCode) {
        yourRoomBox.title = "your room — (none)";
        yourRoomBox.borderColor = theme.c.muted;
        return;
      }

      const room = rooms.find((r) => r.code === myRoomCode);
      if (!room) {
        myRoomCode = null;
        yourRoomBox.title = "your room — (closed)";
        yourRoomBox.borderColor = theme.c.warn;
        return;
      }

      yourRoomBox.title = `your room — ${room.code}`;
      yourRoomBox.borderColor = theme.c.ok;

      for (const p of room.players) {
        const isHost = p.user_id === room.host_user_id;
        const isMine = isMe(p);
        const label = `· ${p.name}${isHost ? " (host)" : ""}${isMine ? " ← you" : ""}`;
        const tone: Tone = isMine ? "self" : "fg";
        const line = new TextRenderable(renderer, {
          content: label,
          fg: theme.c[tone],
        });
        yourRoomList.add(line);
      }
    };

    const isMe = (player: { name: string }) => player.name === identity.name;

    const renderEverything = () => {
      renderRoomsList();
      renderYourRoom();
    };

    const stopThemeWatch = onThemeChange(() => {
      setTopBar(topBarStatus(), topBarTone);
      topBar.borderColor = theme.c.muted;
      roomsBox.borderColor = theme.c.muted;
      rightCol.borderColor = theme.c.muted;
      promptBox.borderColor = theme.c.muted;
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

    const onKeypress = (key: {
      name: string;
      ctrl: boolean;
      meta: boolean;
      preventDefault(): void;
      stopPropagation(): void;
    }) => {
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
      // Hotkey letters are always consumed in hotkeys mode, even when
      // the action they'd trigger is gated out (e.g. `j` while already
      // in a room). Otherwise the keystroke leaks into whatever input
      // has focus (typically chat) and types a literal letter.
      switch (key.name) {
        case "c":
          if (!myRoomCode) createRoom();
          consume();
          break;
        case "j":
          if (!myRoomCode) setMode("join_code");
          consume();
          break;
        case "s":
          if (myRoomCode) startGame();
          consume();
          break;
        case "l":
          if (myRoomCode) leaveRoom();
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
      switch (mode) {
        case "join_code":
          if (focused !== promptInput) promptInput.focus();
          break;
        case "chat":
          break;
        case "hotkeys":
          if (focused) (focused as unknown as { blur?: () => void }).blur?.();
          break;
      }
    };
    renderer.on(CliRenderEvents.FOCUSED_RENDERABLE, onFocusChange);

    promptInput.on(InputRenderableEvents.ENTER, (raw: string) => {
      if (mode !== "join_code") return;
      const code = raw.trim().toUpperCase();
      if (code === "") return;
      void joinRoom(code);
    });

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

    ready
      .then(() => {
        const channel = socket.channel("lobby:main", {});
        lobbyChannel = channel;

        channel.on("rooms", (payload: RoomsPayload) => {
          rooms = payload.rooms;

          if (myRoomCode && !rooms.some((r) => r.code === myRoomCode)) {
            chat?.appendSystem(`* room ${myRoomCode} closed`, "warn");
            myRoomCode = null;
          }

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
            chat.appendSystem(`* entered the lobby as ${identity.name}`, "ok");
            setMode("hotkeys");
            renderEverything();
          })
          .receive("error", (resp: { reason?: string }) => {
            setTopBar(
              `lobby join failed: ${resp?.reason ?? "unknown"}`,
              "error",
            );
          });
      })
      .catch((err: Error) => {
        if (err.message === "auth_rejected") {
          setTopBar("auth rejected — clear local data and re-enter", "error");
        } else {
          setTopBar(`connection failed: ${err.message}`, "error");
        }
      });

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
      return " typing - esc to return to hotkeys";
  }
}
