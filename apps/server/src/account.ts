import type { CharacterInfo, DeviceInfo, RestoreResponse, VersionInfo } from "@road-to-sixty/api";
import { TransactionRollbackError, and, desc, eq, inArray, isNull, sql } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "./db";
import { type Device, pcName } from "./devices";
import { pcRoutes } from "./pc";
import { characters, devices, jobs, user, versionParents, versions } from "./schema";
import { get, removeAll } from "./storage";
import { zip } from "./zip";

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

const info = (d: typeof devices.$inferSelect): DeviceInfo => ({
  id: d.id,
  name: d.name,
  platform: d.platform,
  appVersion: d.appVersion,
  addonVersion: d.addonVersion,
  lastSeenAt: d.lastSeenAt?.toISOString() ?? null,
});

// Characters as folder names: no slashes or characters Windows refuses.
const safe = (s: string) => s.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_");

const mine = (device: Device, id: string) => and(eq(devices.id, id), eq(devices.userId, device.userId), isNull(devices.revokedAt));

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
  })

  .post("/characters/:id/restore", async ({ device, params, body, set }): Promise<RestoreResponse | { error: string }> => {
    const c = await own(device!, params.id);
    const id = Number((body as { version?: unknown } | null)?.version);
    const [source] =
      c && Number.isSafeInteger(id)
        ? await db
            .select()
            .from(versions)
            .where(and(eq(versions.id, id), eq(versions.characterId, c.id), inArray(versions.kind, ["merged", "restore"])))
        : [];
    if (!c || !source) {
      set.status = 404;
      return { error: "no such version" };
    }
    if (source.id === c.headVersionId) {
      set.status = 400;
      return { error: "that is already the current version" };
    }
    // The restore, its parent and the head move are one change: a merge
    // finishing in between must either see all of it or none.
    const version = await db
      .transaction(async (tx) => {
        const [made] = await tx
          .insert(versions)
          .values({
            characterId: c.id,
            deviceId: device!.id,
            kind: "restore",
            fingerprint: source.fingerprint,
            rawSize: source.rawSize,
            dataVersion: source.dataVersion,
            level: source.level,
            status: "accepted",
          })
          .returning({ id: versions.id });
        await tx.insert(versionParents).values({ versionId: made!.id, parentId: source.id });
        const moved = await tx
          .update(characters)
          .set({ headVersionId: made!.id, level: source.level, updatedAt: new Date() })
          .where(and(eq(characters.id, c.id), sql`${characters.headVersionId} IS NOT DISTINCT FROM ${c.headVersionId}::bigint`))
          .returning({ id: characters.id });
        if (moved.length === 0) tx.rollback();
        return made!.id;
      })
      .catch((e) => {
        if (e instanceof TransactionRollbackError) return null;
        throw e;
      });
    if (version === null) {
      set.status = 409;
      return { error: "the journey changed just now; try again" };
    }
    return { version };
  })

  .get("/devices", async ({ device }): Promise<DeviceInfo[]> =>
    (
      await db
        .select()
        .from(devices)
        .where(and(eq(devices.userId, device!.userId), isNull(devices.revokedAt)))
        .orderBy(sql`${devices.lastSeenAt} DESC NULLS LAST`, devices.name)
    ).map(info),
  )

  .patch("/devices/:id", async ({ device, params, body, set }): Promise<DeviceInfo | { error: string }> => {
    const name = pcName((body as { name?: unknown } | null)?.name);
    if (!name) {
      set.status = 400;
      return { error: "a PC needs a name" };
    }
    const [renamed] = await db.update(devices).set({ name }).where(mine(device!, params.id)).returning();
    if (!renamed) {
      set.status = 404;
      return { error: "no such PC" };
    }
    return info(renamed);
  })

  // Each character's current journey as the game would save it, so a
  // player can keep it, or put it back in their SavedVariables folder.
  .get("/export", async ({ device }) => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    const files = [];
    for (const { c, head } of rows) {
      const journey = await get(c.userId, head.fingerprint);
      const data = Buffer.concat([new TextEncoder().encode("RoadToSixtyCharDB = "), journey, new TextEncoder().encode("\n")]);
      files.push({ name: `${safe(c.game)}/${safe(c.realm)}/${safe(c.name)}.lua`, data: new Uint8Array(data) });
    }
    return new Response(zip(files), {
      headers: { "content-type": "application/zip", "content-disposition": 'attachment; filename="road-to-sixty.zip"' },
    });
  })

  // The token stops working at once; the PC's journeys stay where they are.
  .delete("/devices/:id", async ({ device, params, set }) => {
    const [gone] = await db
      .update(devices)
      .set({ revokedAt: new Date() })
      .where(mine(device!, params.id))
      .returning({ id: devices.id });
    if (!gone) {
      set.status = 404;
      return { error: "no such PC" };
    }
    return { ok: true };
  })

  // Spec, "Deleting an account". The PCs are unlinked first so nothing new
  // arrives, and the files go before the rows, so if anything fails part
  // way the player can try again and no file is left with no owner.
  .delete("/account", async ({ device }) => {
    const userId = device!.userId;
    await db.update(devices).set({ revokedAt: new Date() }).where(and(eq(devices.userId, userId), isNull(devices.revokedAt)));
    const theirs = db.select({ id: characters.id }).from(characters).where(eq(characters.userId, userId));
    await db.delete(jobs).where(inArray(jobs.characterId, theirs));
    await removeAll(userId);
    await db.transaction(async (tx) => {
      const theirVersions = tx.select({ id: versions.id }).from(versions).where(inArray(versions.characterId, theirs));
      await tx.delete(versionParents).where(inArray(versionParents.versionId, theirVersions));
      await tx.delete(versions).where(inArray(versions.characterId, theirs));
      await tx.delete(characters).where(eq(characters.userId, userId));
      await tx.delete(devices).where(eq(devices.userId, userId));
      // Sessions, Battle.net accounts and device codes go with the user.
      await tx.delete(user).where(eq(user.id, userId));
    });
    return { ok: true };
  });
