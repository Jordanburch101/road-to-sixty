import { and, desc, eq } from "drizzle-orm";
import { client, db } from "./db";
import { runMerge } from "./lua";
import { characters, devices, jobs, versionParents, versions } from "./schema";
import { fingerprint, get, pack, put } from "./storage";

type Job = typeof jobs.$inferSelect;
type Version = typeof versions.$inferSelect;

const MAX_ATTEMPTS = 3;

// The oldest queued job's id, now marked running, or null.
// ponytail: one worker taking one job at a time, which also keeps two
// uploads of one character from merging at once; take a lock per
// character if more workers ever run.
async function claim(): Promise<number | null> {
  const [row] = await client`
    UPDATE jobs SET state = 'running', attempts = attempts + 1
    WHERE id = (SELECT id FROM jobs WHERE state = 'queued' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
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

  // An upload from a PC that hadn't yet received the latest restore still
  // holds what the restore took out; merging it would undo the restore.
  const [restore] = await db
    .select({ id: versions.id })
    .from(versions)
    .where(and(eq(versions.characterId, character.id), eq(versions.kind, "restore")))
    .orderBy(desc(versions.id))
    .limit(1);
  if (restore && upload.receivedId !== null && upload.receivedId < restore.id) {
    return settle(job, upload, "superseded", "made before the restore reached this PC");
  }

  const [head] = character.headVersionId
    ? await db.select().from(versions).where(eq(versions.id, character.headVersionId))
    : [];
  const result = await runMerge(
    await get(character.userId, upload.fingerprint),
    head ? await get(character.userId, head.fingerprint) : null,
    upload.deviceId ?? "server",
  );
  if (result.from !== null && upload.deviceId) {
    await db.update(devices).set({ dataLayout: result.from }).where(eq(devices.id, upload.deviceId));
  }
  if (!result.ok) return settle(job, upload, "rejected", result.reason);

  const fp = fingerprint(result.journey);
  if (head && fp === head.fingerprint) return settle(job, upload, "accepted"); // nothing new in it
  await put(character.userId, fp, pack(result.journey));
  await db.transaction(async (tx) => {
    const [merged] = await tx
      .insert(versions)
      .values({
        characterId: character.id,
        kind: "merged",
        fingerprint: fp,
        rawSize: result.journey.length,
        dataVersion: result.layout,
        status: "accepted",
      })
      .returning({ id: versions.id });
    await tx
      .insert(versionParents)
      .values([upload.id, ...(head ? [head.id] : [])].map((parentId) => ({ versionId: merged!.id, parentId })));
    await tx
      .update(characters)
      .set({
        headVersionId: merged!.id,
        level: result.level,
        played: result.played === null ? null : Math.round(result.played),
        lastPlayedAt: result.lastSeen === null ? null : new Date(result.lastSeen * 1000),
        updatedAt: new Date(),
      })
      .where(eq(characters.id, character.id));
    await tx.update(versions).set({ status: "accepted", dataVersion: result.from }).where(eq(versions.id, upload.id));
    await tx.update(jobs).set({ state: "done", finishedAt: new Date() }).where(eq(jobs.id, job.id));
  });
}

// Runs the oldest queued job. False when there was none. A job that throws
// (storage down, say) goes back in the queue, up to MAX_ATTEMPTS.
export async function work(): Promise<boolean> {
  const id = await claim();
  if (id === null) return false;
  const [job] = await db.select().from(jobs).where(eq(jobs.id, id));
  try {
    await runJob(job!);
  } catch (e) {
    const error = String(e);
    if (job!.attempts >= MAX_ATTEMPTS) {
      await db.update(jobs).set({ state: "failed", error, finishedAt: new Date() }).where(eq(jobs.id, id));
      await db
        .update(versions)
        .set({ status: "rejected", rejectReason: "the server couldn't merge it" })
        .where(eq(versions.id, job!.versionId));
    } else {
      await db.update(jobs).set({ state: "queued", error }).where(eq(jobs.id, id));
    }
  }
  return true;
}

// Works through the queue until stopped, checking each second when empty.
export function startWorker(): () => void {
  let stopped = false;
  void (async () => {
    // A job left running by a crash or restart goes back in the queue.
    await db.update(jobs).set({ state: "queued" }).where(eq(jobs.state, "running"));
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
