import { eq } from "drizzle-orm";
import { Elysia } from "elysia";
import { db } from "./db";
import { deviceFor } from "./devices";
import { devices } from "./schema";

// Every route the app calls with its PC token starts from this: an unknown
// or unlinked PC is refused, and the PC's last visit and versions noted.
export const pcRoutes = () =>
  new Elysia({ prefix: "/v1" })
    .resolve(async ({ headers }) => ({ device: await deviceFor(headers.authorization) }))
    .onBeforeHandle(({ device, set }) => {
      if (!device) {
        set.status = 401;
        return { error: "unknown or unlinked PC" };
      }
    })
    .onBeforeHandle(async ({ device, query }) => {
      await db
        .update(devices)
        .set({
          lastSeenAt: new Date(),
          ...(query.addon ? { addonVersion: String(query.addon).slice(0, 20) } : {}),
          ...(query.app ? { appVersion: String(query.app).slice(0, 20) } : {}),
        })
        .where(eq(devices.id, device!.id));
    });
