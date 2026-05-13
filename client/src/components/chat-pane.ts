// Chat pane: a reusable scrollable message log + input bound to a
// Phoenix Channel. Used by the lobby (and later the game) scene.
//
// The pane owns a vertical BoxRenderable under `parent`. Messages
// arriving on `channel`'s "say" event are appended to the scroll log;
// Enter on the input pushes a "say" back. System lines (e.g. presence
// notices) can be appended by the parent via the returned handle.
//
// Focus pinning is NOT handled here — the parent scene decides who owns
// the keyboard at any moment. `focus()` is exposed so the parent can
// route focus into the input when it wants typing to land in chat.

import {
  BoxRenderable,
  InputRenderable,
  InputRenderableEvents,
  ScrollBoxRenderable,
  TextRenderable,
  type CliRenderer,
} from "@opentui/core";
import type { Channel } from "phoenix";
import { onThemeChange, theme, type Tone } from "../lib/theme.js";

export interface ChatPaneOptions {
  /** Inputs go here as `say` events. Listens for incoming `say` broadcasts. */
  channel: Channel;
  /** The local user's name — used to color their own messages differently. */
  selfName: string;
  /** Max chars per message (default 500, matches server). */
  maxLength?: number;
}

export interface ChatPaneHandle {
  /** Append a system-style line (no sender, no timestamp). */
  appendSystem(content: string, tone?: Tone): void;
  /** Focus the input (call when the parent scene wants the user typing here). */
  focus(): void;
  /** Detach renderables and listeners. */
  destroy(): void;
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

function formatTime(epochSec: number): string {
  const d = new Date(epochSec * 1000);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function mountChatPane(
  renderer: CliRenderer,
  parent: BoxRenderable,
  options: ChatPaneOptions,
): ChatPaneHandle {
  const { channel, selfName } = options;
  const maxLength = options.maxLength ?? 500;

  const container = new BoxRenderable(renderer, {
    flexGrow: 1,
    flexDirection: "column",
  });

  const log = new ScrollBoxRenderable(renderer, {
    flexGrow: 1,
    stickyScroll: true,
    stickyStart: "bottom",
    contentOptions: { flexDirection: "column" },
  });

  const input = new InputRenderable(renderer, {
    placeholder: "speak into the void",
    maxLength,
    width: "100%",
  });

  container.add(log);
  container.add(input);
  parent.add(container);

  // Track every line we've appended so theme switches can recolor them
  // against the fresh palette. Same pattern as scenes/chat.ts.
  const lines: LoggedLine[] = [];

  const appendLine = (content: string, tone: Tone) => {
    const text = new TextRenderable(renderer, { content, fg: theme.c[tone] });
    log.add(text);
    lines.push({ text, tone });
  };

  // --- channel listeners ---------------------------------------------------

  const sayRef = channel.on("say", (payload: SayPayload) => {
    const ts = formatTime(payload.at);
    const isMe = payload.name === selfName;
    appendLine(
      `[${ts}] ${payload.name}: ${payload.body}`,
      isMe ? "self" : "fg",
    );
  });

  // --- input handling ------------------------------------------------------

  input.on(InputRenderableEvents.ENTER, (raw: string) => {
    const body = raw.trim();
    if (body === "") return;
    input.value = "";
    channel
      .push("say", { body })
      .receive("error", (resp: { reason?: string }) => {
        appendLine(
          `* message rejected: ${resp?.reason ?? "unknown"}`,
          "error",
        );
      });
  });

  // --- theme watch ---------------------------------------------------------

  const stopThemeWatch = onThemeChange(() => {
    for (const line of lines) line.text.fg = theme.c[line.tone];
  });

  return {
    appendSystem(content, tone = "muted") {
      appendLine(content, tone);
    },
    focus() {
      input.focus();
    },
    destroy() {
      stopThemeWatch();
      channel.off("say", sayRef);
      // Removing the container detaches log, input, and all logged
      // text renderables in one shot.
      parent.remove(container.id);
      lines.length = 0;
    },
  };
}
