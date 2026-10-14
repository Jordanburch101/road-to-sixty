import { bigint, bigserial, integer, pgTable, primaryKey, text, timestamp, unique } from "drizzle-orm/pg-core";
import { user } from "./auth-schema";

export * from "./auth-schema";

// A linked PC. Its id is also the PC ID the addon keeps counts under, so a
// journey uploaded from an older addon is prepared with it. tokenHash is
// the hash of the token /v1/link gave the app; the token itself is never
// stored.
// dataLayout is the newest journey layout its addon has written, from its
// uploads, so check never offers it a version it can't read.
export const devices = pgTable("devices", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => user.id),
  name: text("name").notNull(),
  platform: text("platform"),
  appVersion: text("app_version"),
  addonVersion: text("addon_version"),
  dataLayout: integer("data_layout"),
  tokenHash: text("token_hash").notNull().unique(),
  lastSeenAt: timestamp("last_seen_at", { withTimezone: true }),
  revokedAt: timestamp("revoked_at", { withTimezone: true }),
});

// One character of one user. The data holds no name, so this row is how
// the server knows two uploads are the same character.
export const characters = pgTable(
  "characters",
  {
    id: bigserial("id", { mode: "number" }).primaryKey(),
    userId: text("user_id").notNull().references(() => user.id),
    game: text("game").notNull(),
    realm: text("realm").notNull(),
    name: text("name").notNull(),
    class: text("class"),
    level: integer("level"),
    played: integer("played"),
    lastPlayedAt: timestamp("last_played_at", { withTimezone: true }),
    headVersionId: bigint("head_version_id", { mode: "number" }),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [unique().on(t.userId, t.game, t.realm, t.name)],
);

// Every upload, merge result and restore. Ids only grow: the addon takes a
// version that is higher than the one it last brought in. receivedId is the
// version the uploading PC had last received, so an upload made before a
// restore reached it doesn't undo the restore.
export const versions = pgTable("versions", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  characterId: bigint("character_id", { mode: "number" }).notNull().references(() => characters.id),
  deviceId: text("device_id").references(() => devices.id),
  kind: text("kind", { enum: ["upload", "merged", "restore"] }).notNull(),
  fingerprint: text("fingerprint").notNull(),
  rawSize: integer("raw_size").notNull(),
  dataVersion: integer("data_version"),
  // The character's level in this version, for the history the app shows.
  level: integer("level"),
  addonVersion: text("addon_version"),
  receivedId: bigint("received_id", { mode: "number" }),
  status: text("status", { enum: ["pending", "accepted", "rejected", "superseded"] }).notNull(),
  rejectReason: text("reject_reason"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const versionParents = pgTable(
  "version_parents",
  {
    versionId: bigint("version_id", { mode: "number" }).notNull().references(() => versions.id),
    parentId: bigint("parent_id", { mode: "number" }).notNull().references(() => versions.id),
  },
  (t) => [primaryKey({ columns: [t.versionId, t.parentId] })],
);

export const jobs = pgTable("jobs", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  characterId: bigint("character_id", { mode: "number" }).notNull().references(() => characters.id),
  versionId: bigint("version_id", { mode: "number" }).notNull().references(() => versions.id),
  state: text("state", { enum: ["queued", "running", "done", "failed"] }).notNull().default("queued"),
  attempts: integer("attempts").notNull().default(0),
  // A job that threw waits before its next try, so a short storage outage
  // doesn't use up its attempts at once.
  runAfter: timestamp("run_after", { withTimezone: true }).notNull().defaultNow(),
  error: text("error"),
  // When the worker took it. A job left running past the time limit (the
  // worker died, or the database failed under it) is taken back.
  claimedAt: timestamp("claimed_at", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  finishedAt: timestamp("finished_at", { withTimezone: true }),
});
