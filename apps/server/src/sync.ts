import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { and, eq, inArray } from "drizzle-orm";
import { Elysia } from "elysia";
import { db } from "./db";
import { deviceFor } from "./devices";
import { characters, devices, jobs, versions } from "./schema";
import { fingerprint, getPacked, put, unpack } from "./storage";

// The sync API the app calls with its PC token (spec, "Sync API").
export const sync = new Elysia({ prefix: "/v1" })
  .resolve(async ({ headers }) => ({ device: await deviceFor(headers.authorization) }))
  .onBeforeHandle(({ device, set }) => {
    if (!device) {
      set.status = 401;
      return { error: "unknown or unlinked PC" };
    }
  })
  .onBeforeHandle(async ({ device, query }) => {
    await db
      .update(devices)
      .set({ lastSeenAt: new Date(), ...(query.addon ? { addonVersion: query.addon } : {}) })
      .where(eq(devices.id, device!.id));
  })

  // A character's SavedVariables file, zstd-compressed. Stored at once; a
  // job merges it.
  .post(
    "/upload",
    async ({ device, query, request, set }): Promise<UploadResponse | { error: string }> => {
      const { game, realm, name, addon, received } = query;
      if (!game || !realm || !name) {
        set.status = 400;
        return { error: "game, realm and name are required" };
      }
      const packed = new Uint8Array(await request.arrayBuffer());
      let raw: Uint8Array;
      try {
        raw = unpack(packed);
      } catch {
        set.status = 413;
        return { error: "not zstd, or over 32 MB uncompressed" };
      }
      if (raw[0] === 0x1b) {
        set.status = 400;
        return { error: "compiled Lua is refused" };
      }
      const userId = device!.userId;
      await db.insert(characters).values({ userId, game, realm, name }).onConflictDoNothing();
      const [character] = await db
        .select()
        .from(characters)
        .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)));
      const fp = fingerprint(raw);
      const [known] = await db
        .select({ id: versions.id })
        .from(versions)
        .where(and(eq(versions.characterId, character!.id), eq(versions.fingerprint, fp)));
      if (known) return { version: known.id, status: "known" };

      const [last] = received
        ? await db
            .select({ id: versions.id })
            .from(versions)
            .where(and(eq(versions.characterId, character!.id), eq(versions.id, Number(received) || 0)))
        : [];
      await put(userId, fp, packed);
      const id = await db.transaction(async (tx) => {
        const [version] = await tx
          .insert(versions)
          .values({
            characterId: character!.id,
            deviceId: device!.id,
            kind: "upload",
            fingerprint: fp,
            rawSize: raw.length,
            addonVersion: addon ?? null,
            receivedId: last?.id ?? null,
            status: "pending",
          })
          .returning({ id: versions.id });
        await tx.insert(jobs).values({ characterId: character!.id, versionId: version!.id });
        return version!.id;
      });
      return { version: id, status: "queued" };
    },
    { parse: "none" },
  )

  // The newest version of every character of this user, from any PC.
  .get("/check", async ({ device }): Promise<CheckResponse> => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .innerJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    return {
      characters: rows.map(({ c, head }) => {
        // Never a layout newer than this PC's addon writes (spec, "Mismatched
        // addon versions"). A PC that hasn't uploaded yet is unknown; its
        // addon refuses a newer layout itself.
        const updateAddon = device!.dataLayout !== null && (head.dataVersion ?? 0) > device!.dataLayout;
        return {
          game: c.game,
          realm: c.realm,
          name: c.name,
          version: updateAddon ? null : head.id,
          fingerprint: head.fingerprint,
          replace: head.kind === "restore",
          updateAddon,
        };
      }),
    };
  })

  // One merged or restored version, as stored: zstd-compressed Parse.Write text.
  .get("/versions/:id", async ({ device, params, set }) => {
    const [row] = await db
      .select({ v: versions, userId: characters.userId })
      .from(versions)
      .innerJoin(characters, eq(characters.id, versions.characterId))
      .where(and(eq(versions.id, Number(params.id)), inArray(versions.kind, ["merged", "restore"])));
    if (!row || row.userId !== device!.userId) {
      set.status = 404;
      return { error: "no such version" };
    }
    return new Response(await getPacked(row.userId, row.v.fingerprint), { headers: { "content-type": "application/zstd" } });
  });
