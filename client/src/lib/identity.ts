import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync } from "node:fs";

export interface Identity {
  name: string;
  key: string;
  createdAt: string;
}

export interface IdentityStore {
  load(): Identity | null;
  save(identity: { name: string; key: string }): void;
  clear(): void;
  close(): void;
}

const APP_DIR_NAME = "zonia";
const DB_FILE_NAME = "zonia.db";

function dataDir(): string {
  const override = process.env.ZONIA_DATA_DIR;
  if (override) return override;

  if (process.platform === "win32" && process.env.APPDATA) {
    return join(process.env.APPDATA, APP_DIR_NAME);
  }
  const xdg = process.env.XDG_DATA_HOME;
  if (xdg) return join(xdg, APP_DIR_NAME);
  return join(homedir(), ".local", "share", APP_DIR_NAME);
}

// Migrations are append-only. Bump SCHEMA_VERSION and add a function.
const migrations: Array<(db: Database) => void> = [
  (db) => {
    db.run(`
      CREATE TABLE identity (
        id         INTEGER PRIMARY KEY CHECK (id = 1),
        name       TEXT NOT NULL,
        key        TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    `);
  },
];

function migrate(db: Database): void {
  const current = (
    db.query("PRAGMA user_version").get() as { user_version: number }
  ).user_version;
  for (let v = current; v < migrations.length; v++) {
    db.transaction(() => {
      migrations[v]!(db);
      db.run(`PRAGMA user_version = ${v + 1}`);
    })();
  }
}

export function openIdentityStore(): IdentityStore {
  const dir = dataDir();
  mkdirSync(dir, { recursive: true });
  const path = join(dir, DB_FILE_NAME);
  const db = new Database(path, { create: true });
  db.run("PRAGMA journal_mode = WAL");
  migrate(db);

  return {
    load() {
      const row = db
        .query("SELECT name, key, created_at FROM identity WHERE id = 1")
        .get() as { name: string; key: string; created_at: string } | null;
      if (!row) return null;
      return { name: row.name, key: row.key, createdAt: row.created_at };
    },
    save({ name, key }) {
      const createdAt = new Date().toISOString();
      db.run(
        `INSERT INTO identity (id, name, key, created_at) VALUES (1, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET name = excluded.name, key = excluded.key, created_at = excluded.created_at`,
        [name, key, createdAt],
      );
    },
    clear() {
      db.run("DELETE FROM identity WHERE id = 1");
    },
    close() {
      db.close();
    },
  };
}

export function identityDbPath(): string {
  return join(dataDir(), DB_FILE_NAME);
}
