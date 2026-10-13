import { zstdDecompressSync } from "node:zlib";
import { config } from "./config";

// The most a character file may hold uncompressed (spec). A level 60
// journey is 2 to 3 MB.
export const MAX_RAW = 32 * 1024 * 1024;

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
