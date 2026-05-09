// Register scene: prompt for a name, send it to the server, persist on success.
// Used only when the local SQLite has no identity yet.

import {
  BoxRenderable,
  CliRenderEvents,
  InputRenderable,
  InputRenderableEvents,
  TextRenderable,
  type CliRenderer,
  type Renderable,
} from "@opentui/core";
import { registerName, type RegisterResult } from "../lib/socket.js";
import type { IdentityStore } from "../lib/identity.js";
import { onThemeChange, theme } from "../lib/theme.js";

const ERROR_MESSAGES: Record<string, string> = {
  name_invalid: "name must be 2–24 chars, letters/numbers/_/-",
  name_reserved: "that name is reserved, try another",
  name_taken: "name taken, try another",
  join_failed: "could not reach the void, retry",
  timeout: "the void did not answer, retry",
};

export interface RegisterSceneOptions {
  initialValue?: string;
  initialError?: string;
}

export function runRegisterScene(
  renderer: CliRenderer,
  store: IdentityStore,
  options: RegisterSceneOptions = {},
): Promise<RegisterResult> {
  return new Promise((resolve) => {
    const root = new BoxRenderable(renderer, {
      flexGrow: 1,
      alignItems: "center",
      justifyContent: "center",
    });

    const panel = new BoxRenderable(renderer, {
      borderStyle: "rounded",
      padding: 2,
      flexDirection: "column",
      gap: 1,
      alignItems: "center",
    });

    const line1 = new TextRenderable(renderer, {
      content: "you stand at the edge of the void.",
      fg: theme.c.muted,
    });
    const line2 = new TextRenderable(renderer, {
      content: "name yourself, and step in.",
      fg: theme.c.muted,
    });
    const spacer = new BoxRenderable(renderer, { height: 1 });

    const input = new InputRenderable(renderer, {
      placeholder: "name yourself",
      maxLength: 24,
      width: 30,
      value: options.initialValue ?? "",
    });

    const errorLine = new TextRenderable(renderer, {
      content:
        options.initialError && options.initialError !== ""
          ? options.initialError
          : " ",
      fg: theme.c.error,
    });

    panel.add(line1);
    panel.add(line2);
    panel.add(spacer);
    panel.add(input);
    panel.add(errorLine);
    root.add(panel);
    renderer.root.add(root);

    input.focus();

    const refocus = (focused: Renderable | null) => {
      if (focused !== input) input.focus();
    };
    renderer.on(CliRenderEvents.FOCUSED_RENDERABLE, refocus);

    const stopThemeWatch = onThemeChange(() => {
      line1.fg = theme.c.muted;
      line2.fg = theme.c.muted;
      errorLine.fg = theme.c.error;
    });

    let busy = false;
    const setError = (msg: string) => {
      errorLine.content = msg === "" ? " " : msg;
    };

    input.on(InputRenderableEvents.INPUT, () => {
      if (!busy) setError("");
    });

    input.on(InputRenderableEvents.ENTER, async (raw: string) => {
      if (busy) return;
      const name = raw.trim();
      if (name === "") return;

      busy = true;
      setError("…sending your name into the void");

      const result = await registerName(name);
      busy = false;

      if (result.ok) {
        store.save({ name: result.result.name, key: result.result.key });
        renderer.off(CliRenderEvents.FOCUSED_RENDERABLE, refocus);
        stopThemeWatch();
        renderer.root.remove(root.id);
        resolve(result.result);
      } else {
        setError(ERROR_MESSAGES[result.reason] ?? `error: ${result.reason}`);
        input.value = "";
      }
    });
  });
}
