import { zstdDecompressSync } from "node:zlib";
import { config } from "./config";

// The most a character file may hold uncompressed (spec). A level 60
// journey is 2 to 3 MB.
export const MAX_RAW = 32 * 1024 * 1024;

// The most an upload may send compressed. A 32 MB journey compresses far
// below this, so anything bigger isn't a journey.
export const MAX_PACKED = 8 * 1024 * 1024;

const s3 = new Bun.S3Client(config.s3);

const key = (userId: string, fingerprint: string) => `${userId}/${fingerprint}.zst`;

export function fingerprint(raw: Uint8Array): string {
  return new Bun.CryptoHasher("sha256").update(raw).digest("hex");
}

export function pack(raw: Uint8Array): Uint8Array {
  return Bun.zstdCompressSync(raw);
}

// Refuses more than MAX_RAW: a few KB of zstd can unpack to gigabytes.
export function unpack(packed: Uint8Array): Uint8Array {
  return new Uint8Array(zstdDecompressSync(packed, { maxOutputLength: MAX_RAW }));
}

// Identical files share one key, so a file is stored once.
export async function put(userId: string, fp: string, packed: Uint8Array): Promise<void> {
  const k = key(userId, fp);
  if (!(await s3.exists(k))) await s3.write(k, packed);
}

export async function getPacked(userId: string, fp: string): Promise<Uint8Array> {
  return new Uint8Array(await s3.file(key(userId, fp)).arrayBuffer());
}

export async function get(userId: string, fp: string): Promise<Uint8Array> {
  return unpack(await getPacked(userId, fp));
}

// One journey file, for a merge whose account was deleted while it ran.
export async function remove(userId: string, fp: string): Promise<void> {
  await s3.delete(key(userId, fp));
}

// Every journey file of a player. Listing again after each page works
// because the page just listed is gone.
// ponytail: one request per file; a bulk delete if players hold thousands.
export async function removeAll(userId: string): Promise<void> {
  for (;;) {
    const page = await s3.list({ prefix: `${userId}/` });
    const keys = (page.contents ?? []).map((o) => o.key);
    for (const k of keys) await s3.delete(k);
    if (!page.isTruncated || keys.length === 0) return;
  }
}
