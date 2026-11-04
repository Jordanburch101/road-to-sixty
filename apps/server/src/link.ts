import type { LinkResponse } from "@road-to-sixty/api";
import { TransactionRollbackError, and, count, eq, isNull } from "drizzle-orm";
import { dirname } from "node:path";
import { Elysia } from "elysia";
import { auth } from "./auth";
import { db } from "./db";
import { newDevice, pcName } from "./devices";
import { links } from "./limits";
import { devices, session, user } from "./schema";

const MAX_PCS = 20;
const PAGE = Bun.file(`${import.meta.dir}/link.html`);
const COMPASS = Bun.resolveSync("@road-to-sixty/ui/compass.png", import.meta.dir);
const GEIST = Bun.resolveSync("@fontsource-variable/geist/files/geist-latin-wght-normal.woff2", dirname(COMPASS));

// A page's script (src/<page>-page.ts), built for the browser the first time
// it is asked for.
const scripts = new Map<string, Promise<string>>();
export function pageScript(page: "link" | "delete"): Promise<string> {
  let script = scripts.get(page);
  if (!script) {
    script = Bun.build({ entrypoints: [`${import.meta.dir}/${page}-page.ts`], target: "browser", minify: true }).then((r) => {
      if (!r.success) throw new AggregateError(r.logs, `the ${page} page's script didn't build`);
      return r.outputs[0]!.text();
    });
    scripts.set(page, script);
  }
  return script;
}

// Linking a PC (spec, "Linking the app"). The app shows a code from
// /api/auth/device/code, the player approves it on /link, and the app's
// poll of /api/auth/device/token returns a session. The app trades that
// session here for a PC token of its own, and the session ends.
export const link = new Elysia()
  // Never inside another site's frame, where a player could be tricked
  // into clicking Approve.
  .get(
    "/link",
    () =>
      new Response(PAGE, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "content-security-policy": "frame-ancestors 'none'",
          "x-frame-options": "DENY",
        },
      }),
  )
  .get("/link.js", async () => new Response(await pageScript("link"), { headers: { "content-type": "text/javascript; charset=utf-8" } }))
  .get("/link/compass.png", () => new Response(Bun.file(COMPASS), { headers: { "content-type": "image/png" } }))
  .get("/link/geist.woff2", () => new Response(Bun.file(GEIST), { headers: { "content-type": "font/woff2" } }))
  .post("/v1/link", async ({ headers, query, set }): Promise<LinkResponse | { error: string } | Response> => {
    // Only the bearer token counts: a browser's sign-in cookie can't link a PC.
    const signedIn = headers.authorization
      ? await auth.api.getSession({ headers: new Headers({ authorization: headers.authorization }) })
      : null;
    if (!signedIn) {
      set.status = 401;
      return { error: "sign in on the link page first" };
    }
    const userId = signedIn.user.id;
    const tooMany = () => {
      set.status = 429;
      set.headers["retry-after"] = String(links.retryAfter(userId));
      return { error: "too many PCs linked today; try again tomorrow" };
    };
    // Plain text: the app shows the body as why linking didn't finish.
    const full = () => new Response(`This account already has ${MAX_PCS} PCs linked. Unlink one in the app first.`, { status: 409 });
    const linked = async (tx: Pick<typeof db, "select"> = db) => {
      const [row] = await tx
        .select({ n: count() })
        .from(devices)
        .where(and(eq(devices.userId, userId), isNull(devices.revokedAt)));
      return row!.n;
    };
    // Every refusal comes before the sign-in is used up, so the player can
    // link again with the same code once they unlink a PC.
    if (!links.allows(userId)) return tooMany();
    if ((await linked()) >= MAX_PCS) return full();
    const name = pcName(query.name) ?? "PC";
    const platform = query.platform?.slice(0, 20);
    // With the player locked, so two sign-ins linking at once can't both
    // take the last place: counted again, then the sign-in used up (so
    // asking several times at once with one token links one PC), then the
    // day's links counted, which undoes it all if there is no room.
    const made = await db
      .transaction(async (tx) => {
        await tx.select({ id: user.id }).from(user).where(eq(user.id, userId)).for("update");
        if ((await linked(tx)) >= MAX_PCS) return "full" as const;
        const used = await tx.delete(session).where(eq(session.id, signedIn.session.id)).returning({ id: session.id });
        if (used.length === 0) return "used" as const;
        if (!links.take(userId)) tx.rollback();
        return newDevice(userId, name, platform, tx);
      })
      .catch((e) => {
        if (e instanceof TransactionRollbackError) return "too many" as const;
        throw e;
      });
    if (made === "too many") return tooMany();
    if (made === "full") return full();
    if (made === "used") {
      set.status = 401;
      return { error: "sign in on the link page first" };
    }
    return { token: made.token, pc: made.device.id, battletag: signedIn.user.name };
  });
