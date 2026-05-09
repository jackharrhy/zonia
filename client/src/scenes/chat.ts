// Chat scene: ScrollBox of messages on top, status line, Input on the bottom.
// Sticky-bottom scroll, so the latest message is always visible.

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
import type { Channel, Socket } from "phoenix";
import type { Identity } from "../lib/identity.js";
import { connectAuthed } from "../lib/socket.js";
import { onThemeChange, theme, type Tone } from "../lib/theme.js";

interface PresenceState {
  [userId: string]: { metas: Array<{ name: string; online_at: number }> };
}

interface PresenceDiff {
  joins: PresenceState;
  leaves: PresenceState;
}

interface SayPayload {
  name: string;
  body: string;
  at: number;
}

interface LoggedLine {
  text: TextRenderable;
  tone: Tone;
}

export function runChatScene(renderer: CliRenderer, identity: Identity): void {
  // ── layout ────────────────────────────────────────────────────────────
  const root = new BoxRenderable(renderer, {
    flexGrow: 1,
    flexDirection: "column",
  });

  const log = new ScrollBoxRenderable(renderer, {
    flexGrow: 1,
    stickyScroll: true,
    stickyStart: "bottom",
    contentOptions: { flexDirection: "column" },
  });

  // Tone for the status line, tracked separately so we can repaint on theme
  // change without losing the current state.
  let statusTone: Tone = "muted";
  const statusLine = new TextRenderable(renderer, {
    content: ` ${identity.name} • connecting…`,
    fg: theme.c[statusTone],
  });

  const input = new InputRenderable(renderer, {
    placeholder: "speak into the void",
    maxLength: 500,
    width: "100%",
  });

  root.add(log);
  root.add(statusLine);
  root.add(input);
  renderer.root.add(root);
  input.focus();

  // Pin focus to the input. If anything else (a click, tab, etc.) takes
  // focus, snap it back. The renderer fires FOCUSED_RENDERABLE whenever the
  // focused element changes.
  renderer.on(CliRenderEvents.FOCUSED_RENDERABLE, (focused: Renderable | null) => {
    if (focused !== input) input.focus();
  });

  // ── helpers ───────────────────────────────────────────────────────────

  // Each appended line keeps its semantic tone so we can repaint on theme
  // toggle. The list grows unbounded for v1 — a chat-history cap can come
  // later.
  const lines: LoggedLine[] = [];

  const appendLine = (content: string, tone: Tone = "fg") => {
    const text = new TextRenderable(renderer, { content, fg: theme.c[tone] });
    log.add(text);
    lines.push({ text, tone });
  };

  const setStatus = (msg: string, tone: Tone = "muted") => {
    statusTone = tone;
    statusLine.content = ` ${identity.name} • ${msg}`;
    statusLine.fg = theme.c[tone];
  };

  const formatTime = (epochSec: number) => {
    const d = new Date(epochSec * 1000);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };

  // Repaint everything when the terminal flips dark↔light.
  onThemeChange(() => {
    statusLine.fg = theme.c[statusTone];
    for (const line of lines) line.text.fg = theme.c[line.tone];
  });

  // ── socket ────────────────────────────────────────────────────────────
  const { socket, ready, onStatusChange } = connectAuthed(identity.key);

  onStatusChange((s) => {
    if (s === "connected") setStatus("connected", "ok");
    else setStatus("reconnecting…", "warn");
  });

  ready
    .then(() => joinWorld(socket))
    .catch((err: Error) => {
      if (err.message === "auth_rejected") {
        appendLine(
          "* the void does not recognize you. clear local data and re-enter.",
          "error",
        );
        setStatus("auth rejected", "error");
      } else {
        appendLine(`* connection failed: ${err.message}`, "error");
      }
    });

  function joinWorld(socket: Socket) {
    const channel: Channel = socket.channel("world:lobby", {});
    let seenInitialPresence = false;
    const known = new Map<string, string>(); // userId -> name

    channel.on("presence_state", (state: PresenceState) => {
      for (const [userId, entry] of Object.entries(state)) {
        const meta = entry.metas[0];
        if (meta) known.set(userId, meta.name);
      }
      seenInitialPresence = true;
    });

    channel.on("presence_diff", (diff: PresenceDiff) => {
      if (!seenInitialPresence) return;
      for (const [userId, entry] of Object.entries(diff.joins)) {
        const meta = entry.metas[0];
        if (!meta) continue;
        // Skip our own join — we already know we entered.
        if (meta.name === identity.name && !known.has(userId)) {
          known.set(userId, meta.name);
          continue;
        }
        if (!known.has(userId)) {
          known.set(userId, meta.name);
          appendLine(`* ${meta.name} entered the void`, "muted");
        }
      }
      for (const [userId, entry] of Object.entries(diff.leaves)) {
        const meta = entry.metas[0];
        if (!meta) continue;
        known.delete(userId);
        appendLine(`* ${meta.name} vanished`, "muted");
      }
    });

    channel.on("say", (payload: SayPayload) => {
      const ts = formatTime(payload.at);
      const isMe = payload.name === identity.name;
      appendLine(
        `[${ts}] ${payload.name}: ${payload.body}`,
        isMe ? "self" : "fg",
      );
    });

    channel
      .join()
      .receive("ok", () => {
        appendLine(`* you entered the void as ${identity.name}`, "ok");
        setStatus("connected", "ok");
      })
      .receive("error", (resp: { reason?: string }) => {
        appendLine(
          `* could not enter the world: ${resp?.reason ?? "unknown"}`,
          "error",
        );
      });

    input.on(InputRenderableEvents.ENTER, (raw: string) => {
      const body = raw.trim();
      if (body === "") return;
      input.value = "";
      // phoenix client buffers pushes until rejoined, so disconnects are fine.
      channel
        .push("say", { body })
        .receive("error", (resp: { reason?: string }) => {
          appendLine(
            `* message rejected: ${resp?.reason ?? "unknown"}`,
            "error",
          );
        });
    });
  }
}
