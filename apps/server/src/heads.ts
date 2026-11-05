import { and, desc, eq, inArray, isNull, lt } from "drizzle-orm";
import { client, db } from "./db";
import { versions } from "./schema";
import { getPackedIfThere, isThere, unpack } from "./storage";

type Version = typeof versions.$inferSelect;

// What to build on in place of a character's head: the head's journey, or,
// when its file is missing from storage, the newest merged or restored
// version before it whose file is there (#114). Null when none is. Without
// this, a missing head file failed every merge and restore of that
// character for good, and only a database edit by hand got it going again.
// The play only the lost file held is gone either way; the PCs that
// played it send it again with their next upload.
export async function readableHead(userId: string, head: Version): Promise<{ version: Version; journey: Uint8Array } | null> {
  const packed = await getPackedIfThere(userId, head.fingerprint);
  if (packed) return { version: head, journey: unpack(packed) };
  console.error(`character ${head.characterId}: its head, version ${head.id}, has no file in storage; building on an older version`);
  const older = await db
    .select()
    .from(versions)
    .where(
      and(
        eq(versions.characterId, head.characterId),
        inArray(versions.kind, ["merged", "restore"]),
        isNull(versions.prunedAt),
        lt(versions.id, head.id),
      ),
    )
    .orderBy(desc(versions.id));
  // Identical files are stored once, so each file is tried once.
  const tried = new Set([head.fingerprint]);
  for (const v of older) {
    if (tried.has(v.fingerprint)) continue;
    tried.add(v.fingerprint);
    const p = await getPackedIfThere(userId, v.fingerprint);
    if (p) return { version: v, journey: unpack(p) };
  }
  return null;
}

// The daily check that every head's file is in storage, so a lost one is
// seen in the log before a player meets it.
export async function checkHeads(): Promise<{ checked: number; missing: number[] }> {
  const rows = await client`
    SELECT c.id, c.user_id, v.id AS version, v.fingerprint
    FROM characters c JOIN versions v ON v.id = c.head_version_id
    ORDER BY c.id`;
  const missing: number[] = [];
  let unknown = 0;
  for (const r of rows) {
    // Storage failing for one doesn't stop the rest.
    const there = await isThere(String(r.user_id), String(r.fingerprint)).catch(() => null);
    if (there === null) unknown++;
    else if (!there) {
      missing.push(Number(r.id));
      console.error(`heads: character ${r.id}'s head, version ${r.version}, has no file in storage`);
    }
  }
  console.log(`heads: ${rows.length} checked, ${missing.length} missing${unknown ? `, ${unknown} couldn't be checked` : ""}`);
  return { checked: rows.length, missing };
}
