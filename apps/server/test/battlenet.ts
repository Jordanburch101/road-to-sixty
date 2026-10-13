// A stand-in for Battle.net's sign-in, so the tests sign in without a
// browser: it signs in whoever `player` says. BATTLENET_URL in .env.test
// points the server here.
import { app } from "../src/app";

export const player = { id: 1234, battletag: "Ann#1234" };

Bun.serve({
  port: 58444,
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/authorize") {
      const back = new URL(url.searchParams.get("redirect_uri")!);
      back.searchParams.set("code", `code-${player.id}`);
      back.searchParams.set("state", url.searchParams.get("state")!);
      return Response.redirect(back.toString(), 302);
    }
    if (url.pathname === "/token") return Response.json({ access_token: `token-${player.id}`, token_type: "bearer", expires_in: 3600 });
    if (url.pathname === "/userinfo") {
      // An id of 0 stands for a reply that names no account at all.
      return Response.json(player.id ? { sub: String(player.id), id: player.id, battletag: player.battletag } : { battletag: player.battletag });
    }
    return new Response("not found", { status: 404 });
  },
});

const cookies = (r: Response) => r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");

// Signs in through the whole Battle.net round trip and returns the sign-in
// cookie, as a browser would hold it.
export async function signIn(as: Partial<typeof player> = {}): Promise<string> {
  Object.assign(player, { id: 1234, battletag: "Ann#1234" }, as);
  const start = await app.handle(
    new Request("http://localhost:3000/api/auth/sign-in/social", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:3000" },
      body: JSON.stringify({ provider: "battlenet", callbackURL: "/link" }),
    }),
  );
  const { url } = (await start.json()) as { url: string };
  const authorize = await fetch(url, { redirect: "manual" });
  const callback = await app.handle(
    new Request(authorize.headers.get("location")!, {
      headers: { cookie: cookies(start), "user-agent": "Test Browser", "x-forwarded-for": "203.0.113.9" },
    }),
  );
  if (callback.status !== 302) throw new Error(`sign-in failed: ${callback.status} ${await callback.text()}`);
  return cookies(callback);
}
