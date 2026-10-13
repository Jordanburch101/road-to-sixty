import { and, eq, isNull } from "drizzle-orm";
import { db } from "./db";
import { devices } from "./schema";

export type Device = typeof devices.$inferSelect;

const hash = (token: string) => new Bun.CryptoHasher("sha256").update(token).digest("hex");

// A new linked PC with a random token, which is shown once and stored only
// as its hash. Stands in for Better Auth's device sign-in until it is built.
export async function newDevice(userId: string, name: string): Promise<{ device: Device; token: string }> {
  const token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
  const [device] = await db.insert(devices).values({ id: crypto.randomUUID(), userId, name, tokenHash: hash(token) }).returning();
  return { device: device!, token };
}

// The PC an Authorization: Bearer header belongs to, unless revoked.
export async function deviceFor(authorization: string | undefined): Promise<Device | null> {
  const token = authorization?.match(/^Bearer (\S+)$/)?.[1];
  if (!token) return null;
  const [device] = await db.select().from(devices).where(and(eq(devices.tokenHash, hash(token)), isNull(devices.revokedAt)));
  return device ?? null;
}
