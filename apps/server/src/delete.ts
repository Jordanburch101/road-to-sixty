import { Elysia } from "elysia";
import { deleteEverything } from "./account";
import { auth } from "./auth";
import { config } from "./config";
import { pageScript } from "./link";

// How recent the Battle.net sign-in that deletes everything must be. A PC
// token alone can't (#99): it may come from a link code the player was
// tricked into approving, and nothing else here can't be undone.
export const FRESH_SECONDS = 10 * 60;

const PAGE = Bun.file(`${import.meta.dir}/delete.html`);
const ORIGIN = new URL(config.auth.url).origin;

// Delete everything (spec, "Deleting an account"): the app opens /delete,
// the player signs in with Battle.net there and confirms.
export const remove = new Elysia()
  // Never inside another site's frame, where a player could be tricked
  // into clicking Delete.
  .get(
    "/delete",
    () =>
      new Response(PAGE, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "content-security-policy": "frame-ancestors 'none'",
          "x-frame-options": "DENY",
        },
      }),
  )
  .get("/delete.js", async () => new Response(await pageScript("delete"), { headers: { "content-type": "text/javascript; charset=utf-8" } }))
  .post("/delete", async ({ request, set }) => {
    // Only from this server's own page. The sign-in cookie is SameSite=Lax,
    // so another site's form doesn't send it either.
    if (request.headers.get("origin") !== ORIGIN) {
      set.status = 403;
      return { error: "Delete from the Road to Sixty page." };
    }
    // Only the browser's signed cookie counts. The device sign-in a link
    // code gives is a session too, made just now, and whoever holds a
    // phished code holds it: as a bearer token it must not delete anything.
    const signedIn = await auth.api.getSession({ headers: new Headers({ cookie: request.headers.get("cookie") ?? "" }) });
    if (!signedIn) {
      set.status = 401;
      return { error: "Sign in with Battle.net first." };
    }
    if (Date.now() - signedIn.session.createdAt.getTime() > FRESH_SECONDS * 1000) {
      set.status = 401;
      return { error: "Sign in with Battle.net again to delete." };
    }
    await deleteEverything(signedIn.user.id);
    return { ok: true };
  });
