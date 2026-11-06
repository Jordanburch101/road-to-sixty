import { client } from "./db";
import type { versions } from "./schema";
import { getPackedIfThere, isThere, unpack } from "./storage";

type Version = typeof versions.$inferSelect;

// How far back readableHead looks before giving up.
const MAX_STEPS = 1000;

// What to build on in place of a character's head: the head's journey, or,
// when its file is missing from storage, the nearest version it was built
// from whose file is there (#114). Null when none is. Without this, a
// missing head file failed every merge and restore of that character for
// good, and only a database edit by hand got it going again. The play only
// the lost file held is gone from the server; the PCs that played it send
// it again with their next upload of that character.
export async function readableHead(userId: string, head: Version): Promise<{ id: number; journey: Uint8Array } | null> {
  const packed = await getPackedIfThere(userId, head.fingerprint);
  if (packed) return { id: head.id, journey: unpack(packed) };
  console.error(`character ${head.characterId}: its head, version ${head.id}, has no file in storage; building on an earlier one`);
  // Back along what the head was made from, never by age: a restore's way
  // back is its source, a merged version's the version it merged onto
  // (its other parent is the upload, which may hold what a restore took
  // out). The head holds all of each, so play a restore took out can't come
  // back, as it would from the version the restore replaced: newer than
  // the source, and kept for good. A pruned one is passed through unread,
  // as its file may be going.
  const chain = await client`
    WITH RECURSIVE chain(id, depth) AS (
      SELECT ${head.id}::bigint, 0
      UNION ALL
      SELECT p.parent_id, chain.depth + 1
      FROM chain
      JOIN version_parents p ON p.version_id = chain.id
      JOIN versions v ON v.id = p.parent_id AND v.kind IN ('merged', 'restore')
      WHERE chain.depth < ${MAX_STEPS})
    SELECT v.id, v.fingerprint FROM chain JOIN versions v ON v.id = chain.id
    WHERE chain.depth > 0 AND v.pruned_at IS NULL
    ORDER BY chain.depth`;
  // Identical files are stored once, so each file is tried once: a
  // restore's file is its source's.
  const tried = new Set([head.fingerprint]);
  for (const v of chain) {
    const fp = String(v.fingerprint);
    if (tried.has(fp)) continue;
    tried.add(fp);
    const p = await getPackedIfThere(userId, fp);
    if (p) return { id: Number(v.id), journey: unpack(p) };
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
