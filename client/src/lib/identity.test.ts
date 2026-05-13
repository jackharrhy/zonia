import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openIdentityStore } from "./identity.js";

let tmpDir: string;
let previousEnv: string | undefined;

beforeEach(() => {
  previousEnv = process.env.ZONIA_DATA_DIR;
  tmpDir = mkdtempSync(join(tmpdir(), "zonia-test-"));
  process.env.ZONIA_DATA_DIR = tmpDir;
});

afterEach(() => {
  if (previousEnv === undefined) {
    delete process.env.ZONIA_DATA_DIR;
  } else {
    process.env.ZONIA_DATA_DIR = previousEnv;
  }
  try {
    rmSync(tmpDir, { recursive: true, force: true });
  } catch {
    // ignore cleanup failures
  }
});

function userVersion(path: string): number {
  const db = new Database(path);
  try {
    const row = db.query("PRAGMA user_version").get() as {
      user_version: number;
    };
    return row.user_version;
  } finally {
    db.close();
  }
}

function tableExists(path: string, name: string): boolean {
  const db = new Database(path);
  try {
    const row = db
      .query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      )
      .get(name) as { name: string } | null;
    return row !== null;
  } finally {
    db.close();
  }
}

describe("identity store migrations", () => {
  test("v1 → v2 upgrade preserves identity row and creates game_history", () => {
    const dbPath = join(tmpDir, "zonia.db");

    // Simulate a v1 client that wrote a row before v2 existed.
    {
      const seed = new Database(dbPath, { create: true });
      seed.run("PRAGMA journal_mode = WAL");
      seed.run(`
        CREATE TABLE identity (
          id         INTEGER PRIMARY KEY CHECK (id = 1),
          name       TEXT NOT NULL,
          key        TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      `);
      seed.run(
        `INSERT INTO identity (id, name, key, created_at) VALUES (1, ?, ?, ?)`,
        ["alice", "secret-key-v1", "2024-01-02T03:04:05.000Z"],
      );
      seed.run("PRAGMA user_version = 1");
      seed.close();
    }

    expect(userVersion(dbPath)).toBe(1);

    const store = openIdentityStore();
    try {
      const id = store.load();
      expect(id).not.toBeNull();
      expect(id?.name).toBe("alice");
      expect(id?.key).toBe("secret-key-v1");
      expect(id?.createdAt).toBe("2024-01-02T03:04:05.000Z");
    } finally {
      store.close();
    }

    expect(userVersion(dbPath)).toBe(2);
    expect(tableExists(dbPath, "identity")).toBe(true);
    expect(tableExists(dbPath, "game_history")).toBe(true);
  });

  test("fresh install lands at v2 with both tables", () => {
    const dbPath = join(tmpDir, "zonia.db");
    const store = openIdentityStore();
    try {
      expect(store.load()).toBeNull();
    } finally {
      store.close();
    }

    expect(userVersion(dbPath)).toBe(2);
    expect(tableExists(dbPath, "identity")).toBe(true);
    expect(tableExists(dbPath, "game_history")).toBe(true);
  });
});

describe("game history", () => {
  test("recordGameHistory + listGameHistory ordering and limit", () => {
    const store = openIdentityStore();
    try {
      store.recordGameHistory({
        roomCode: "AAAA",
        finishedAt: "2024-01-01T00:00:00.000Z",
        placement: 3,
        stars: 1,
        coins: 5,
        board: "zonia-isle",
      });
      store.recordGameHistory({
        roomCode: "BBBB",
        finishedAt: "2024-01-02T00:00:00.000Z",
        placement: 1,
        stars: 4,
        coins: 12,
        board: "zonia-isle",
      });
      store.recordGameHistory({
        roomCode: "CCCC",
        finishedAt: "2024-01-03T00:00:00.000Z",
        placement: 2,
        stars: 2,
        coins: 7,
        board: "zonia-isle",
      });

      const all = store.listGameHistory();
      expect(all).toHaveLength(3);
      expect(all[0]?.roomCode).toBe("CCCC");
      expect(all[1]?.roomCode).toBe("BBBB");
      expect(all[2]?.roomCode).toBe("AAAA");

      const latest = store.listGameHistory(1);
      expect(latest).toHaveLength(1);
      expect(latest[0]?.roomCode).toBe("CCCC");
      expect(latest[0]?.placement).toBe(2);
      expect(latest[0]?.stars).toBe(2);
      expect(latest[0]?.coins).toBe(7);
      expect(latest[0]?.board).toBe("zonia-isle");
    } finally {
      store.close();
    }
  });

  test("recordGameHistory swallows errors when DB is closed", () => {
    const store = openIdentityStore();
    store.close();

    const originalError = console.error;
    let calls = 0;
    console.error = () => {
      calls++;
    };
    try {
      expect(() => {
        store.recordGameHistory({
          roomCode: "DEAD",
          finishedAt: "2024-01-04T00:00:00.000Z",
          placement: 1,
          stars: 0,
          coins: 0,
          board: "zonia-isle",
        });
      }).not.toThrow();
      expect(calls).toBeGreaterThan(0);
    } finally {
      console.error = originalError;
    }
  });
});
