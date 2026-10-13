import type { LinkResponse } from "@road-to-sixty/api";
import { eq } from "drizzle-orm";
import { Elysia } from "elysia";
import { auth } from "./auth";
import { db } from "./db";
import { newDevice } from "./devices";
import { session } from "./schema";

const PAGE = Bun.file(`${import.meta.dir}/link.html`);

// Linking a PC (spec, "Linking the app"). The app shows a code from
// /api/auth/device/code, the player approves it on /link, and the app's
// poll of /api/auth/device/token returns a session. The app trades that
// session here for a PC token of its own, and the session ends.
export const link = new Elysia()
  .get("/link", () => new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } }))
  .post("/v1/link", async ({ headers, query, set }): Promise<LinkResponse | { error: string }> => {
    // Only the bearer token counts: a browser's sign-in cookie can't link a PC.
    const signedIn = headers.authorization
      ? await auth.api.getSession({ headers: new Headers({ authorization: headers.authorization }) })
      : null;
    if (!signedIn) {
      set.status = 401;
      return { error: "sign in on the link page first" };
    }
    const name = query.name?.trim().slice(0, 100) || "PC";
    const platform = query.platform?.slice(0, 20);
    const { device, token } = await newDevice(signedIn.user.id, name, platform);
    await db.delete(session).where(eq(session.id, signedIn.session.id));
    return { token, pc: device.id };
  });
