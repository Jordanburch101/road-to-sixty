import { and, eq, inArray, isNull, lt } from "drizzle-orm";
import { client, db } from "./db";
import { characters, deviceCode, session, verification, versions } from "./schema";
import { remove } from "./storage";

export type Pruned = { characterId: number; versions: number; files: number; bytes: number };

// The daily clean-up (spec, "Version clean-up"): each character keeps its
// newest 100 merged and restored versions, the head, and the ones kept for
// good (the newest of each finished week, and any version a restore
// replaced); an upload's file goes once its merge is done. Rows stay, with
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

  const pruned: Pruned[] = [];
  // One account at a time, so each query uses the character and version
  // indexes and the whole candidate list is never held at once.
  for (const { id: userId } of await client`SELECT id FROM "user" ORDER BY id`) {
    // One account failing (storage down for its files, say) doesn't stop
    // the clean-up for everyone after it.
    try {
      pruned.push(...(await pruneAccount(String(userId), mode)));
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
  const total = pruned.reduce((t, p) => ({ versions: t.versions + p.versions, files: t.files + p.files, bytes: t.bytes + p.bytes }), {
    versions: 0,
    files: 0,
    bytes: 0,
  });
  console.log(
    `prune (${mode}): ${total.versions} versions, ${total.files} files, ${(total.bytes / 1e6).toFixed(1)} MB, across ${pruned.length} characters`,
  );
  return pruned;
}

type Row = { id: number; fingerprint: string; rawSize: number; characterId: number; chosen: boolean };

async function pruneAccount(userId: string, mode: "dry" | "on"): Promise<Pruned[]> {
  const rows: Row[] = (
    await client`
      SELECT v.id, v.fingerprint, v.raw_size, v.character_id,
        CASE WHEN v.kind = 'upload' THEN
          -- A merged upload's file is done with. A refused or replaced one
          -- is held 30 days: the app never sends a file twice, so it may be
          -- the only copy of that session.
          (v.status = 'accepted' OR (v.status IN ('rejected', 'superseded') AND v.created_at < now() - interval '30 days'))
          AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.version_id = v.id AND j.state IN ('queued', 'running'))
        ELSE
          -- History offers the newest 100 and the ones kept for good, so
          -- anything else can't be reached.
          NOT v.weekly AND v.id IS DISTINCT FROM c.head_version_id
          AND row_number() OVER (PARTITION BY v.character_id, v.kind = 'upload' ORDER BY v.id DESC) > 100
        END AS chosen
      FROM characters c JOIN versions v ON v.character_id = c.id
      WHERE c.user_id = ${userId} AND v.pruned_at IS NULL`
  ).map((r: Record<string, unknown>) => ({
    id: Number(r.id),
    fingerprint: String(r.fingerprint),
    rawSize: Number(r.raw_size),
    characterId: Number(r.character_id),
    chosen: r.chosen === true,
  }));
  const chosen = rows.filter((r) => r.chosen);
  if (chosen.length === 0) return [];
  // Marked before anything is deleted: a restore locks its source and
  // checks it isn't pruned, so it either finishes first (and its new row,
  // sharing the file, is counted as kept below) or is refused.
  if (mode === "on") {
    for (let i = 0; i < chosen.length; i += 5000) {
      await db
        .update(versions)
        .set({ prunedAt: new Date() })
        .where(inArray(versions.id, chosen.slice(i, i + 5000).map((r) => r.id)));
    }
  }
  // Identical files are stored once, so a file goes only when no version
  // that stays has it. Read again after marking, so a restore that finished
  // in between is counted.
  const kept = new Set<string>(
    mode === "on"
      ? (
          await db
            .selectDistinct({ fp: versions.fingerprint })
            .from(versions)
            .innerJoin(characters, eq(characters.id, versions.characterId))
            .where(and(eq(characters.userId, userId), isNull(versions.prunedAt)))
        ).map((k) => k.fp)
      : rows.filter((r) => !r.chosen).map((r) => r.fingerprint),
  );
  const files = new Map<string, number>();
  for (const r of chosen) if (!kept.has(r.fingerprint)) files.set(r.fingerprint, r.rawSize);
  // ponytail: a crash here leaves files no row needs, which is only
  // storage; a sweep of unreferenced files would find them.
  if (mode === "on") for (const fp of files.keys()) await remove(userId, fp);

  const byCharacter = new Map<number, Row[]>();
  for (const r of chosen) byCharacter.set(r.characterId, [...(byCharacter.get(r.characterId) ?? []), r]);
  return [...byCharacter].map(([characterId, mine]) => {
    const myFiles = [...new Set<string>(mine.map((r) => r.fingerprint))].filter((fp) => files.has(fp));
    return { characterId, versions: mine.length, files: myFiles.length, bytes: myFiles.reduce((sum, fp) => sum + files.get(fp)!, 0) };
  });
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
