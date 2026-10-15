import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { and, count, desc, eq, inArray, max, sql } from "drizzle-orm";
import { db } from "./db";
import { pcRoutes } from "./pc";
import { characters, devices, jobs, versions } from "./schema";
import { uploads } from "./limits";
import { fingerprint, getPacked, MAX_PACKED, put, unpack } from "./storage";
import { SERVER_FAILED } from "./worker";

const MAX_FIELD = 64;
const MAX_CHARACTERS = 100;

// The sync API the app calls with its PC token (spec, "Sync API").
export const sync = pcRoutes()
  // A character's SavedVariables file, zstd-compressed. Stored at once; a
  // job merges it.
  .post(
    "/upload",
    async ({ device, query, request, set }): Promise<UploadResponse | { error: string } | Response> => {
      if (!uploads.take(device!.id)) {
        set.status = 429;
        set.headers["retry-after"] = String(uploads.retryAfter(device!.id));
        return { error: "too many uploads" };
      }
      const { game, realm, name, addon, received } = query;
      if (!game || !realm || !name) {
        set.status = 400;
        return { error: "game, realm and name are required" };
      }
      if ([game, realm, name, addon].some((v) => v !== undefined && v.length > MAX_FIELD)) {
        set.status = 400;
        return { error: `game, realm, name and addon are at most ${MAX_FIELD} characters` };
      }
      const packed = new Uint8Array(await request.arrayBuffer());
      // Bun stops a bigger body in production; this also covers a body sent without its length.
      if (packed.length > MAX_PACKED) {
        set.status = 413;
        return { error: "over 8 MB compressed" };
      }
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
      const [existing] = await db
        .select({ id: characters.id })
        .from(characters)
        .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)));
      if (!existing) {
        const [held] = await db.select({ n: count() }).from(characters).where(eq(characters.userId, userId));
        // Plain text: the app shows the body as the reason on the character's row.
        if (held!.n >= MAX_CHARACTERS) return new Response(`This account has reached ${MAX_CHARACTERS} characters`, { status: 422 });
        await db.insert(characters).values({ userId, game, realm, name }).onConflictDoNothing();
      }
      const [character] = await db
        .select()
        .from(characters)
        .where(and(eq(characters.userId, userId), eq(characters.game, game), eq(characters.realm, realm), eq(characters.name, name)));
      const fp = fingerprint(raw);
      // A file the server failed to merge (storage down, say) gets another
      // try; one the merge refused stays refused.
      const known = (
        await db
          .select({ id: versions.id, status: versions.status, rejectReason: versions.rejectReason })
          .from(versions)
          .where(and(eq(versions.characterId, character!.id), eq(versions.fingerprint, fp)))
      ).find((v) => !(v.status === "rejected" && v.rejectReason === SERVER_FAILED));
      if (known) return { version: known.id, status: "known" };

      const [last] = received
        ? await db
            .select({ id: versions.id })
            .from(versions)
            .where(and(eq(versions.characterId, character!.id), eq(versions.id, Number(received) || 0)))
        : [];
      await put(userId, fp, packed);
      const id = await db.transaction(async (tx) => {
        // The newer file holds everything the older one did, so this PC's
        // older upload of the character still waiting in the queue is
        // dropped. Not across a restore (a different received id): those
        // two were made against different journeys. A job the worker has
        // started is no longer queued, so it is left alone.
        const receivedId = last?.id ?? null;
        const folded = await tx
          .update(jobs)
          .set({ state: "done", error: "folded into a newer upload", finishedAt: new Date() })
          .where(
            and(
              eq(jobs.state, "queued"),
              inArray(
                jobs.versionId,
                tx
                  .select({ id: versions.id })
                  .from(versions)
                  .where(
                    and(
                      eq(versions.characterId, character!.id),
                      eq(versions.deviceId, device!.id),
                      eq(versions.kind, "upload"),
                      eq(versions.status, "pending"),
                      sql`${versions.receivedId} IS NOT DISTINCT FROM ${receivedId}::bigint`,
                    ),
                  ),
              ),
            ),
          )
          .returning({ versionId: jobs.versionId });
        if (folded.length > 0) {
          await tx
            .update(versions)
            .set({ status: "superseded", rejectReason: "folded into a newer upload" })
            .where(inArray(versions.id, folded.map((f) => f.versionId)));
        }
        const [version] = await tx
          .insert(versions)
          .values({
            characterId: character!.id,
            deviceId: device!.id,
            kind: "upload",
            fingerprint: fp,
            rawSize: raw.length,
            addonVersion: addon ?? null,
            receivedId,
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

  // The newest version of every character of this user, from any PC, and
  // whether this PC's latest upload of each was refused.
  .get("/check", async ({ device }): Promise<CheckResponse> => {
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .leftJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
    // A restore replaces until this PC shows, by an upload's received, that
    // its addon took in the restore or a version after it. Merging instead
    // would bring back what the restore took out.
    const lastRestore = new Map(
      (
        await db
          .select({ characterId: versions.characterId, id: max(versions.id) })
          .from(versions)
          .innerJoin(characters, eq(characters.id, versions.characterId))
          .where(and(eq(characters.userId, device!.userId), eq(versions.kind, "restore")))
          .groupBy(versions.characterId)
      ).map((r) => [r.characterId, r.id ?? 0]),
    );
    const applied = new Map(
      (
        await db
          .select({ characterId: versions.characterId, id: max(versions.receivedId) })
          .from(versions)
          .where(and(eq(versions.deviceId, device!.id), eq(versions.kind, "upload")))
          .groupBy(versions.characterId)
      ).map((r) => [r.characterId, r.id ?? 0]),
    );
    // This PC's newest upload of each character: if the merge refused it,
    // the app says so until a newer one goes in.
    const newest = new Map(
      (
        await db
          .selectDistinctOn([versions.characterId], {
            characterId: versions.characterId,
            status: versions.status,
            reason: versions.rejectReason,
          })
          .from(versions)
          .where(and(eq(versions.deviceId, device!.id), eq(versions.kind, "upload")))
          .orderBy(versions.characterId, desc(versions.id))
      ).map((r) => [r.characterId, r]),
    );
    return {
      characters: rows
        // One with nothing merged yet is listed only to say why it was refused.
        .filter(({ c, head }) => head !== null || newest.get(c.id)?.status === "rejected")
        .map(({ c, head }) => {
          // Never a layout newer than this PC's addon writes (spec, "Mismatched
          // addon versions"). A PC that hasn't uploaded yet is unknown; its
          // addon refuses a newer layout itself.
          const updateAddon = head !== null && device!.dataLayout !== null && (head.dataVersion ?? 0) > device!.dataLayout;
          const last = newest.get(c.id);
          const lastRestoreId = lastRestore.get(c.id) ?? 0;
          const restore = head !== null && (applied.get(c.id) ?? 0) < lastRestoreId ? lastRestoreId : null;
          return {
            game: c.game,
            realm: c.realm,
            name: c.name,
            version: head === null || updateAddon ? null : head.id,
            fingerprint: head?.fingerprint ?? "",
            restore,
            replace: restore !== null,
            updateAddon,
            rejected: last?.status === "rejected" ? (last.reason ?? "refused") : null,
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
