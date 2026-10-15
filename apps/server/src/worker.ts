import { and, desc, eq, sql } from "drizzle-orm";
import { client, db } from "./db";
import { LIMITS, runMerge, type Window } from "./lua";
import { characters, devices, jobs, versionParents, versions } from "./schema";
import { MAX_RAW, fingerprint, get, pack, put, remove } from "./storage";

type Job = typeof jobs.$inferSelect;
type Version = typeof versions.$inferSelect;

// Tries for about a day, waiting twice as long each time up to six hours,
// so an outage or a server bug fixed by the next deploy doesn't cost uploads.
export const MAX_ATTEMPTS = 12;
export const RETRY_SECONDS = 30;
const MAX_WAIT_SECONDS = 6 * 3600;
// A running job older than this was abandoned: the merge's own limit plus margin.
const STALE_SECONDS = LIMITS.seconds + 240;

// Why an upload was rejected when the server, not the merge, failed: the
// same file sent again gets another try.
export const SERVER_FAILED = "the server couldn't merge it";

// A due job's id, now marked running, or null: the oldest of the account the
// worker served least recently, so one account's queue can't hold up
// everyone else's. A job left running longer than STALE_SECONDS counts as
// due again.
// ponytail: one worker taking one job at a time, which also keeps two
// uploads of one character from merging at once; take a lock per
// character if more workers ever run.
async function claim(): Promise<number | null> {
  const [row] = await client`
    UPDATE jobs SET state = 'running', attempts = attempts + 1, claimed_at = now()
    WHERE id = (
      SELECT j.id FROM jobs j JOIN characters c ON c.id = j.character_id
      WHERE (j.state = 'queued' AND j.run_after <= now())
         OR (j.state = 'running' AND (j.claimed_at IS NULL OR j.claimed_at < now() - ${STALE_SECONDS} * interval '1 second'))
      ORDER BY (
        SELECT max(j2.claimed_at) FROM jobs j2 JOIN characters c2 ON c2.id = j2.character_id WHERE c2.user_id = c.user_id
      ) NULLS FIRST, j.id
      LIMIT 1 FOR UPDATE OF j SKIP LOCKED)
    RETURNING id`;
  return row ? Number(row.id) : null;
}

async function settle(job: Job, upload: Version, status: "accepted" | "rejected" | "superseded", reason?: string) {
  await db.transaction(async (tx) => {
    await tx.update(versions).set({ status, rejectReason: reason ?? null }).where(eq(versions.id, upload.id));
    await tx
      .update(jobs)
      .set({ state: status === "rejected" ? "failed" : "done", error: reason ?? null, finishedAt: new Date() })
      .where(eq(jobs.id, job.id));
  });
}

// Merges one upload into its character's journey (spec, "Merge jobs").
async function runJob(job: Job) {
  const [upload] = await db.select().from(versions).where(eq(versions.id, job.versionId));
  const [character] = await db.select().from(characters).where(eq(characters.id, job.characterId));
  if (!upload || !character) throw new Error(`job ${job.id} has no upload or character`);

  // An upload from a PC that hadn't yet taken in the latest restore (or
  // never received anything, like a copied WTF folder) may still hold what
  // restores took out. It is merged without the play inside their windows,
  // so the restore holds and the PC's own new play is kept.
  const restores = await db
    .select({ id: versions.id, removed: versions.removed })
    .from(versions)
    .where(and(eq(versions.characterId, character.id), eq(versions.kind, "restore")))
    .orderBy(desc(versions.id));
  const stale = restores.length > 0 && (upload.receivedId ?? 0) < restores[0]!.id;
  // A restore made before windows were kept can't be stripped, so such an
  // upload is set aside, as it was then.
  if (stale && restores.some((r) => r.removed === null)) {
    return settle(job, upload, "superseded", "made before the restore reached this PC");
  }
  const windows: Window[] = stale ? restores.flatMap((r) => JSON.parse(r.removed!) as Window[]) : [];

  const [head] = character.headVersionId
    ? await db.select().from(versions).where(eq(versions.id, character.headVersionId))
    : [];
  const result = await runMerge(
    await get(character.userId, upload.fingerprint),
    head ? await get(character.userId, head.fingerprint) : null,
    upload.deviceId ?? "server",
    windows,
  );
  if (!result.ok) return settle(job, upload, "rejected", result.reason);
  // Never lowered: an alt's file untouched since an older addon is still
  // in its old layout.
  if (result.from !== null && upload.deviceId) {
    await db
      .update(devices)
      .set({ dataLayout: sql`GREATEST(coalesce(${devices.dataLayout}, 0), ${result.from})` })
      .where(eq(devices.id, upload.deviceId));
  }

  // Stored, it could never be unpacked again, and every later merge of
  // this character would fail on it.
  if (result.journey.length > MAX_RAW) return settle(job, upload, "rejected", "the merged journey would be too big to store");
  const fp = fingerprint(result.journey);
  if (head && fp === head.fingerprint) return settle(job, upload, "accepted"); // nothing new in it
  await put(character.userId, fp, pack(result.journey));
  try {
    await db.transaction(async (tx) => {
      const [merged] = await tx
        .insert(versions)
        .values({
          characterId: character.id,
          kind: "merged",
          fingerprint: fp,
          rawSize: result.journey.length,
          dataVersion: result.layout,
          level: result.level,
          status: "accepted",
        })
        .returning({ id: versions.id });
      await tx
        .insert(versionParents)
        .values([upload.id, ...(head ? [head.id] : [])].map((parentId) => ({ versionId: merged!.id, parentId })));
      const updated = await tx
        .update(characters)
        .set({
          headVersionId: merged!.id,
          level: result.level,
          // A file from before the addon recorded the class doesn't forget it.
          ...(result.class ? { class: result.class } : {}),
          played: result.played === null ? null : Math.round(result.played),
          lastPlayedAt: result.lastSeen === null ? null : new Date(result.lastSeen * 1000),
          updatedAt: new Date(),
        })
        // Unless the head moved meanwhile (a restore, or a second worker during
        // a deploy): writing over it would drop that version from the journey.
        .where(and(eq(characters.id, character.id), sql`${characters.headVersionId} IS NOT DISTINCT FROM ${head?.id ?? null}::bigint`))
        .returning({ id: characters.id });
      if (updated.length === 0) throw new Error("the head moved during the merge");
      await tx.update(versions).set({ status: "accepted", dataVersion: result.from }).where(eq(versions.id, upload.id));
      await tx.update(jobs).set({ state: "done", finishedAt: new Date() }).where(eq(jobs.id, job.id));
    });
  } catch (e) {
    // The player deleted everything while this merge ran: their files went
    // then, so this one goes too instead of staying with no owner.
    const [still] = await db.select({ id: characters.id }).from(characters).where(eq(characters.id, character.id));
    if (!still) await remove(character.userId, fp);
    throw e;
  }
}

// Runs the oldest due job. False when there was none. A job that throws
// goes back in the queue with a longer wait, up to MAX_ATTEMPTS. If the
// database fails even for that, the job stays running and is taken back
// once it is stale.
export async function work(): Promise<boolean> {
  const id = await claim();
  if (id === null) return false;
  try {
    const [job] = await db.select().from(jobs).where(eq(jobs.id, id));
    try {
      await runJob(job!);
    } catch (e) {
      const error = String(e);
      // The same file hits the same limit again, so it gets one more try
      // (the server may just have been busy), not a day of them.
      const limit = /over the (memory|time) limit|didn't finish in time/.test(error);
      if (job!.attempts >= (limit ? 2 : MAX_ATTEMPTS)) {
        await db.update(jobs).set({ state: "failed", error, finishedAt: new Date() }).where(eq(jobs.id, id));
        await db
          .update(versions)
          .set({ status: "rejected", rejectReason: SERVER_FAILED })
          .where(eq(versions.id, job!.versionId));
      } else {
        const wait = Math.min(RETRY_SECONDS * 2 ** (job!.attempts - 1), MAX_WAIT_SECONDS);
        await db
          .update(jobs)
          .set({ state: "queued", error, runAfter: new Date(Date.now() + wait * 1000) })
          .where(eq(jobs.id, id));
      }
    }
  } catch (e) {
    console.error(`worker: job ${id}:`, e);
  }
  return true;
}

// Works through the queue until stopped, checking each second when empty.
export function startWorker(): () => void {
  let stopped = false;
  void (async () => {
    while (!stopped) {
      const worked = await work().catch((e) => {
        console.error("worker:", e);
        return false;
      });
      if (!worked) await Bun.sleep(1000);
    }
  })();
  return () => {
    stopped = true;
  };
}
