import type { LinkResponse } from "@road-to-sixty/api";
import { and, count, eq, isNull } from "drizzle-orm";
import { dirname } from "node:path";
import { Elysia } from "elysia";
import { auth } from "./auth";
import { db } from "./db";
import { newDevice, pcName } from "./devices";
import { links } from "./limits";
import { devices, session } from "./schema";

const MAX_PCS = 20;
const PAGE = Bun.file(`${import.meta.dir}/link.html`);
const COMPASS = Bun.resolveSync("@road-to-sixty/ui/compass.png", import.meta.dir);
const GEIST = Bun.resolveSync("@fontsource-variable/geist/files/geist-latin-wght-normal.woff2", dirname(COMPASS));

// The page's script, built for the browser the first time it is asked for.
let script: Promise<string> | undefined;
function pageScript(): Promise<string> {
  script ??= Bun.build({ entrypoints: [`${import.meta.dir}/link-page.ts`], target: "browser", minify: true }).then((r) => {
    if (!r.success) throw new AggregateError(r.logs, "the link page's script didn't build");
    return r.outputs[0]!.text();
  });
  return script;
}

// Linking a PC (spec, "Linking the app"). The app shows a code from
// /api/auth/device/code, the player approves it on /link, and the app's
// poll of /api/auth/device/token returns a session. The app trades that
// session here for a PC token of its own, and the session ends.
export const link = new Elysia()
  .get("/link", () => new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } }))
  .get("/link.js", async () => new Response(await pageScript(), { headers: { "content-type": "text/javascript; charset=utf-8" } }))
  .get("/link/compass.png", () => new Response(Bun.file(COMPASS), { headers: { "content-type": "image/png" } }))
  .get("/link/geist.woff2", () => new Response(Bun.file(GEIST), { headers: { "content-type": "font/woff2" } }))
  .post("/v1/link", async ({ headers, query, set }): Promise<LinkResponse | { error: string } | Response> => {
    // Only the bearer token counts: a browser's sign-in cookie can't link a PC.
    const signedIn = headers.authorization
      ? await auth.api.getSession({ headers: new Headers({ authorization: headers.authorization }) })
      : null;
    // The sign-in is used up first, so asking several times at once with
    // one token links one PC.
    const used = signedIn ? await db.delete(session).where(eq(session.id, signedIn.session.id)).returning({ id: session.id }) : [];
    if (!signedIn || used.length === 0) {
      set.status = 401;
      return { error: "sign in on the link page first" };
    }
    if (!links.take(signedIn.user.id)) {
      set.status = 429;
      set.headers["retry-after"] = String(links.retryAfter(signedIn.user.id));
      return { error: "too many PCs linked today; try again tomorrow" };
    }
    const [linked] = await db
      .select({ n: count() })
      .from(devices)
      .where(and(eq(devices.userId, signedIn.user.id), isNull(devices.revokedAt)));
    // Plain text: the app shows the body as why linking didn't finish.
    if (linked!.n >= MAX_PCS) return new Response(`This account already has ${MAX_PCS} PCs linked. Unlink one in the app first.`, { status: 409 });
    const name = pcName(query.name) ?? "PC";
    const platform = query.platform?.slice(0, 20);
    const { device, token } = await newDevice(signedIn.user.id, name, platform);
    return { token, pc: device.id, battletag: signedIn.user.name };
  });
