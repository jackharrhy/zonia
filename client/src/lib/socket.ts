// Thin wrappers over phoenix.Socket for the two flavors of connection.
// The phoenix client auto-reconnects with backoff out of the box; we just
// surface open/close events so the UI can dim while reconnecting.

import { Socket, type Channel } from "phoenix";

// __ZONIA_BAKED_SERVER__ is replaced at build time via `bun build --define`
// in scripts/prepare-npm.ts (see the `define` block there). For `bun run
// dev` it stays as the literal string below, which falls through to the
// localhost default.
//
// Runtime resolution order:
//   1. ZONIA_SERVER env var (user override, highest priority)
//   2. value baked in at compile time
//   3. ws://localhost:4000/socket (dev fallback)
declare const __ZONIA_BAKED_SERVER__: string;

const baked =
  typeof __ZONIA_BAKED_SERVER__ === "string" ? __ZONIA_BAKED_SERVER__ : "";

export const DEFAULT_ENDPOINT =
  process.env.ZONIA_SERVER ?? baked ?? "ws://localhost:4000/socket";

export interface RegisterResult {
  name: string;
  key: string;
}

export type RegisterError =
  | "name_invalid"
  | "name_reserved"
  | "name_taken"
  | string;

/**
 * Open an unauthenticated socket, join the throwaway register channel, send
 * one `register` event, return the result. Tears the socket down on the way
 * out either way.
 */
export async function registerName(
  name: string,
  endpoint: string = DEFAULT_ENDPOINT,
): Promise<{ ok: true; result: RegisterResult } | { ok: false; reason: RegisterError }> {
  const socket = new Socket(endpoint, {});
  socket.connect();

  const channel = socket.channel("register:lobby", {});

  const joined = await new Promise<boolean>((resolve) => {
    channel
      .join()
      .receive("ok", () => resolve(true))
      .receive("error", () => resolve(false))
      .receive("timeout", () => resolve(false));
  });

  if (!joined) {
    socket.disconnect();
    return { ok: false, reason: "join_failed" };
  }

  const result = await new Promise<
    { ok: true; result: RegisterResult } | { ok: false; reason: RegisterError }
  >((resolve) => {
    channel
      .push("register", { name })
      .receive("ok", (resp: RegisterResult) => resolve({ ok: true, result: resp }))
      .receive("error", (resp: { reason?: string }) =>
        resolve({ ok: false, reason: resp?.reason ?? "unknown" }),
      )
      .receive("timeout", () => resolve({ ok: false, reason: "timeout" }));
  });

  socket.disconnect();
  return result;
}

export interface AuthedSocket {
  socket: Socket;
  /** Resolves on first successful open; rejects if the server refuses the key. */
  ready: Promise<void>;
  onStatusChange(cb: (status: "connected" | "disconnected") => void): void;
}

/**
 * Open an authenticated socket. The phoenix client retries forever with
 * backoff on transport errors; we only reject `ready` if the *first* attempt
 * is rejected by the server (invalid key), which we detect via a transient
 * close before any open. Subsequent disconnects flip status only.
 */
export function connectAuthed(
  key: string,
  endpoint: string = DEFAULT_ENDPOINT,
): AuthedSocket {
  const socket = new Socket(endpoint, { params: { key } });

  let firstOpen = true;
  let resolveReady: () => void;
  let rejectReady: (reason: unknown) => void;
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });

  const listeners: Array<(s: "connected" | "disconnected") => void> = [];
  const emit = (s: "connected" | "disconnected") => listeners.forEach((cb) => cb(s));

  socket.onOpen(() => {
    if (firstOpen) {
      firstOpen = false;
      resolveReady();
    }
    emit("connected");
  });

  socket.onClose(() => {
    if (firstOpen) {
      // Closed before we ever opened — server rejected the key.
      firstOpen = false;
      rejectReady(new Error("auth_rejected"));
    }
    emit("disconnected");
  });

  socket.onError(() => {
    emit("disconnected");
  });

  socket.connect();

  return {
    socket,
    ready,
    onStatusChange(cb) {
      listeners.push(cb);
    },
  };
}

export type { Channel };
