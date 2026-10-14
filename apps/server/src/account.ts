import type { CharacterInfo, VersionInfo } from "@road-to-sixty/api";
import { and, desc, eq, inArray } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "./db";
import type { Device } from "./devices";
import { pcRoutes } from "./pc";
import { characters, devices, versionParents, versions } from "./schema";

const HISTORY = 100;

export type Character = typeof characters.$inferSelect;

// The character with this id, if it belongs to the PC's player.
export async function own(device: Device, id: string): Promise<Character | null> {
  if (!/^\d+$/.test(id)) return null;
  const [c] = await db
    .select()
    .from(characters)
    .where(and(eq(characters.id, Number(id)), eq(characters.userId, device.userId)));
  return c ?? null;
}

// The name of the PC whose upload made each of these merged versions.
async function madeBy(ids: number[]): Promise<Map<number, string>> {
  if (ids.length === 0) return new Map();
  const upload = alias(versions, "upload");
  const rows = await db
    .select({ id: versionParents.versionId, name: devices.name })
    .from(versionParents)
    .innerJoin(upload, and(eq(upload.id, versionParents.parentId), eq(upload.kind, "upload")))
    .innerJoin(devices, eq(devices.id, upload.deviceId))
    .where(inArray(versionParents.versionId, ids));
  return new Map(rows.map((r) => [r.id, r.name]));
}

// The version each of these restores brought back.
async function restoredFrom(ids: number[]): Promise<Map<number, { id: number; createdAt: string }>> {
  if (ids.length === 0) return new Map();
  const source = alias(versions, "source");
  const rows = await db
    .select({ id: versionParents.versionId, sourceId: source.id, createdAt: source.createdAt })
    .from(versionParents)
    .innerJoin(source, eq(source.id, versionParents.parentId))
    .where(inArray(versionParents.versionId, ids));
  return new Map(rows.map((r) => [r.id, { id: r.sourceId, createdAt: r.createdAt.toISOString() }]));
}

// The account API (spec, "Account API"), for the app's window.
export const account = pcRoutes()
  .get("/characters", async ({ device }): Promise<CharacterInfo[]> => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    const from = await madeBy(rows.map((r) => r.head.id));
    return rows.map(({ c, head }) => ({
      id: c.id,
      game: c.game,
      realm: c.realm,
      name: c.name,
      class: c.class,
      level: c.level,
      played: c.played,
      lastPlayedAt: c.lastPlayedAt?.toISOString() ?? null,
      syncedAt: head.createdAt.toISOString(),
      syncedFrom: from.get(head.id) ?? null,
    }));
  })

  .get("/characters/:id/versions", async ({ device, params, set }): Promise<VersionInfo[] | { error: string }> => {
    const c = await own(device!, params.id);
    if (!c) {
      set.status = 404;
      return { error: "no such character" };
    }
    const rows = await db
      .select()
      .from(versions)
      .where(and(eq(versions.characterId, c.id), inArray(versions.kind, ["merged", "restore"])))
      .orderBy(desc(versions.id))
      .limit(HISTORY);
    const from = await madeBy(rows.filter((v) => v.kind === "merged").map((v) => v.id));
    const restored = await restoredFrom(rows.filter((v) => v.kind === "restore").map((v) => v.id));
    return rows.map((v) => ({
      id: v.id,
      kind: v.kind as "merged" | "restore",
      createdAt: v.createdAt.toISOString(),
      level: v.level,
      from: from.get(v.id) ?? null,
      restoredFrom: restored.get(v.id) ?? null,
      current: v.id === c.headVersionId,
    }));
  });
