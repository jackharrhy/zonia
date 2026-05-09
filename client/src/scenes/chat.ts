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

  const statusLine = new TextRenderable(renderer, {
    content: ` ${identity.name} • connecting…`,
    fg: "#6b7280",
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
  const appendLine = (content: string, fg = "#e5e7eb") => {
    log.add(new TextRenderable(renderer, { content, fg }));
  };

  const setStatus = (msg: string, fg = "#6b7280") => {
    statusLine.content = ` ${identity.name} • ${msg}`;
    statusLine.fg = fg;
  };

  const formatTime = (epochSec: number) => {
    const d = new Date(epochSec * 1000);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };

  // ── socket ────────────────────────────────────────────────────────────
  const { socket, ready, onStatusChange } = connectAuthed(identity.key);

  onStatusChange((s) => {
    if (s === "connected") setStatus("connected", "#10b981");
    else setStatus("reconnecting…", "#f59e0b");
  });

  ready
    .then(() => joinWorld(socket))
    .catch((err: Error) => {
      if (err.message === "auth_rejected") {
        appendLine(
          "* the void does not recognize you. clear local data and re-enter.",
          "#ef4444",
        );
        setStatus("auth rejected", "#ef4444");
      } else {
        appendLine(`* connection failed: ${err.message}`, "#ef4444");
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
          appendLine(`* ${meta.name} entered the void`, "#9ca3af");
        }
      }
      for (const [userId, entry] of Object.entries(diff.leaves)) {
        const meta = entry.metas[0];
        if (!meta) continue;
        known.delete(userId);
        appendLine(`* ${meta.name} vanished`, "#9ca3af");
      }
    });

    channel.on("say", (payload: SayPayload) => {
      const ts = formatTime(payload.at);
      const isMe = payload.name === identity.name;
      appendLine(
        `[${ts}] ${payload.name}: ${payload.body}`,
        isMe ? "#60a5fa" : "#e5e7eb",
      );
    });

    channel
      .join()
      .receive("ok", () => {
        appendLine(`* you entered the void as ${identity.name}`, "#10b981");
        setStatus("connected", "#10b981");
      })
      .receive("error", (resp: { reason?: string }) => {
        appendLine(`* could not enter the world: ${resp?.reason ?? "unknown"}`, "#ef4444");
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
            "#ef4444",
          );
        });
    });
  }
}
