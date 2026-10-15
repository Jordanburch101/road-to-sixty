import { and, eq, inArray, isNull, lt, notInArray } from "drizzle-orm";
import { client, db } from "./db";
import { characters, deviceCode, session, verification, versions } from "./schema";
import { remove } from "./storage";

export type Pruned = { characterId: number; versions: number; files: number; bytes: number };

// The daily clean-up (spec, "Version clean-up"): every merged and restored
// version from the last 30 days stays, then the newest of each finished
// week; an upload's file goes once its merge is done. Rows stay, with
// pruned_at set, because restores' windows, parents and the known-file
// check still need them.
// ponytail: a merge whose result is identical to a file being deleted here
// can still lose it (put skips a file that exists); an upload in the same
// spot fails its merge and the app sends it again. Lock per account if
// that is ever seen.
export async function prune(mode: "dry" | "on"): Promise<Pruned[]> {
  // A week still under way is left alone, so the mark lands on the week's
  // last version and each finished week gets exactly one. Weeks are UTC.
  await client`
    UPDATE versions SET weekly = true
    WHERE id IN (
      SELECT DISTINCT ON (character_id, date_trunc('week', created_at, 'UTC')) id
      FROM versions v
      WHERE kind IN ('merged', 'restore') AND pruned_at IS NULL
        AND created_at < date_trunc('week', now(), 'UTC')
        AND NOT EXISTS (
          SELECT 1 FROM versions w
          WHERE w.character_id = v.character_id AND w.weekly
            AND date_trunc('week', w.created_at, 'UTC') = date_trunc('week', v.created_at, 'UTC'))
      ORDER BY character_id, date_trunc('week', created_at, 'UTC'), id DESC)`;

  const rows = await client`
    SELECT v.id, v.fingerprint, v.raw_size, v.character_id, c.user_id
    FROM versions v JOIN characters c ON c.id = v.character_id
    WHERE v.pruned_at IS NULL AND (
      (v.kind = 'upload' AND v.status IN ('accepted', 'rejected', 'superseded')
        AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.version_id = v.id AND j.state IN ('queued', 'running')))
      OR (v.kind IN ('merged', 'restore') AND NOT v.weekly
        AND v.created_at < now() - interval '30 days'
        AND v.id IS DISTINCT FROM c.head_version_id))
    ORDER BY v.id`;
  const chosen: { id: number; fingerprint: string; rawSize: number; characterId: number; userId: string }[] = rows.map((r: Record<string, unknown>) => ({
    id: Number(r.id),
    fingerprint: String(r.fingerprint),
    rawSize: Number(r.raw_size),
    characterId: Number(r.character_id),
    userId: String(r.user_id),
  }));

  const pruned: Pruned[] = [];
  for (const userId of Array.from(new Set<string>(chosen.map((c) => c.userId)))) {
    // One account failing (storage down for its files, say) doesn't stop
    // the clean-up for everyone after it.
    try {
      const theirs = chosen.filter((c) => c.userId === userId);
      const ids = theirs.map((c) => c.id);
      // Marked before anything is deleted: a restore locks its source and
      // checks it isn't pruned, so it either finishes first (and its new row,
      // sharing the file, is counted as kept below) or is refused.
      if (mode === "on") await db.update(versions).set({ prunedAt: new Date() }).where(inArray(versions.id, ids));
      // Identical files are stored once, so a file goes only when no version
      // that stays has it.
      const kept = new Set(
        (
          await db
            .selectDistinct({ fp: versions.fingerprint })
            .from(versions)
            .innerJoin(characters, eq(characters.id, versions.characterId))
            .where(and(eq(characters.userId, userId), isNull(versions.prunedAt), notInArray(versions.id, ids)))
        ).map((k) => k.fp),
      );
      const files = new Map<string, number>();
      for (const c of theirs) if (!kept.has(c.fingerprint)) files.set(c.fingerprint, c.rawSize);
      // ponytail: a crash here leaves files no row needs, which is only
      // storage; a sweep of unreferenced files would find them.
      if (mode === "on") for (const fp of files.keys()) await remove(userId, fp);
      for (const characterId of Array.from(new Set<number>(theirs.map((c) => c.characterId)))) {
        const mine = theirs.filter((c) => c.characterId === characterId);
        const myFiles = Array.from(new Set<string>(mine.map((c) => c.fingerprint))).filter((fp) => files.has(fp));
        pruned.push({
          characterId,
          versions: mine.length,
          files: myFiles.length,
          bytes: myFiles.reduce((sum, fp) => sum + files.get(fp)!, 0),
        });
      }
    } catch (e) {
      console.error("prune: an account failed, carrying on:", e);
    }
  }
  if (mode === "on") {
    // Nothing reads a finished job once its version is settled.
    await client`DELETE FROM jobs WHERE state IN ('done', 'failed') AND finished_at < now() - interval '30 days'`;
    // Better Auth checks expiry when a row is used but never clears these.
    for (const table of [session, verification, deviceCode]) await db.delete(table).where(lt(table.expiresAt, new Date()));
  }
  for (const p of pruned) {
    console.log(`prune (${mode}): character ${p.characterId}: ${p.versions} versions, ${p.files} files, ${(p.bytes / 1e6).toFixed(1)} MB`);
  }
  return pruned;
}

const DAY = 24 * 3600 * 1000;

// A few minutes after start, so a deploy settles first, then once a day.
export function startPrune(mode: "dry" | "on" | "off") {
  if (mode === "off") return;
  const run = () => prune(mode).catch((e) => console.error("prune:", e));
  setTimeout(() => {
    void run();
    setInterval(run, DAY);
  }, 5 * 60 * 1000);
}
