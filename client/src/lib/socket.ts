import { Socket, type Channel } from "phoenix";

// 1. ZONIA_SERVER env var (user override, highest priority)
// 2. value baked in at compile time
// 3. ws://localhost:4000/socket (dev fallback)
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
): Promise<
  { ok: true; result: RegisterResult } | { ok: false; reason: RegisterError }
> {
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
      .receive("ok", (resp: RegisterResult) =>
        resolve({ ok: true, result: resp }),
      )
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
  ready: Promise<void>;
  onStatusChange(cb: (status: "connected" | "disconnected") => void): void;
}

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
  const emit = (s: "connected" | "disconnected") =>
    listeners.forEach((cb) => cb(s));

  socket.onOpen(() => {
    if (firstOpen) {
      firstOpen = false;
      resolveReady();
    }
    emit("connected");
  });

  socket.onClose(() => {
    if (firstOpen) {
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
