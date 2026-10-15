import { eq } from "drizzle-orm";
import { Elysia } from "elysia";
import { db } from "./db";
import { deviceFor } from "./devices";
import { accountRequests, requests } from "./limits";
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
    // A runaway app is told to wait instead of keeping the server busy.
    .onBeforeHandle(({ device, set }) => {
      for (const [w, key] of [
        [requests, device!.id],
        [accountRequests, device!.userId],
      ] as const) {
        if (!w.take(key)) {
          set.status = 429;
          set.headers["retry-after"] = String(w.retryAfter(key));
          return { error: "too many requests" };
        }
      }
    })
    // Written at most every 10 minutes, or when a version changes: the app
    // checks in every few minutes, and a write per request adds up.
    .onBeforeHandle(async ({ device, query }) => {
      const addon = query.addon ? String(query.addon).slice(0, 20) : null;
      const app = query.app ? String(query.app).slice(0, 20) : null;
      const stale = !device!.lastSeenAt || Date.now() - device!.lastSeenAt.getTime() > 10 * 60 * 1000;
      if (!stale && (addon ?? device!.addonVersion) === device!.addonVersion && (app ?? device!.appVersion) === device!.appVersion) return;
      await db
        .update(devices)
        .set({ lastSeenAt: new Date(), ...(addon ? { addonVersion: addon } : {}), ...(app ? { appVersion: app } : {}) })
        .where(eq(devices.id, device!.id));
    });
