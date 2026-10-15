import { Elysia } from "elysia";
import { account } from "./account";
import { auth } from "./auth";
import { link } from "./link";
import { sync } from "./sync";

// The most any request but an upload may send. Sign-in stores some fields
// as they come, and routes parse a body before checking the PC's token, so
// a big body is refused before anything reads it.
const MAX_BODY = 16 * 1024;

// Without a length, reads at most MAX_BODY of a copy to find out.
async function tooBig(request: Request): Promise<boolean> {
  const length = request.headers.get("content-length");
  if (length !== null) return Number(length) > MAX_BODY;
  if (!request.body) return false;
  const reader = request.clone().body!.getReader();
  for (let read = 0; ; ) {
    const { done, value } = await reader.read();
    if (done) return false;
    read += value.length;
    if (read > MAX_BODY) {
      await reader.cancel();
      return true;
    }
  }
}

export const app = new Elysia()
  .onRequest(async ({ request, set }) => {
    if (new URL(request.url).pathname === "/v1/upload") return;
    if (await tooBig(request)) {
      set.status = 413;
      return { error: "too big" };
    }
  })
  .get("/health", () => "ok")
  // Better Auth reads the request itself, so Elysia must leave the body alone.
  .all("/api/auth/*", ({ request }) => auth.handler(request), { parse: "none" })
  .use(link)
  .use(sync)
  .use(account);
