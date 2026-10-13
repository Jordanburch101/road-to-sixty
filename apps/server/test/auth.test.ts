import { APP_CLIENT_ID, type LinkResponse } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { eq } from "drizzle-orm";
import { app } from "../src/app";
import { accountHash } from "../src/auth";
import { db } from "../src/db";
import { account, deviceCode as deviceCodes, devices, session, user } from "../src/schema";
import { signIn } from "./battlenet";
import { reset } from "./helpers";

beforeEach(reset);

const post = (path: string, body: object, headers: Record<string, string> = {}) =>
  app.handle(
    new Request(`http://localhost:3000${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:3000", ...headers },
      body: JSON.stringify(body),
    }),
  );
const get = (path: string, headers: Record<string, string> = {}) => app.handle(new Request(`http://localhost:3000${path}`, { headers }));

test("signing in with Battle.net makes a player named by BattleTag, keyed by a hash of the account ID", async () => {
  const cookie = await signIn({ id: 1234, battletag: "Ann#1234" });
  const signedIn = (await (await get("/api/auth/get-session", { cookie })).json()) as { user: { name: string } };
  expect(signedIn.user.name).toBe("Ann#1234");
  const [row] = await db.select().from(account);
  expect(row).toMatchObject({ providerId: "battlenet", accountId: accountHash(1234), accessToken: null, idToken: null });
  expect(JSON.stringify(await db.select().from(user))).not.toContain("1234@");
});

test("a Battle.net reply that names no account signs no one in", async () => {
  await signIn({ id: 0, battletag: "Ann#1111" });
  await signIn({ id: 0, battletag: "Bob#2222" });
  expect(await db.select().from(user)).toEqual([]);
});

test("a sign-in keeps no IP address or browser details", async () => {
  await signIn();
  const [row] = await db.select().from(session);
  expect(row).toMatchObject({ ipAddress: null, userAgent: null });
});

test("signing in again is the same player, with the BattleTag brought up to date", async () => {
  await signIn({ id: 1234, battletag: "Ann#1234" });
  await signIn({ id: 1234, battletag: "Annie#1234" });
  await signIn({ id: 5678, battletag: "Bob#5678" });
  const users = await db.select().from(user).orderBy(user.name);
  expect(users.map((u) => u.name)).toEqual(["Annie#1234", "Bob#5678"]);
  expect((await db.select().from(account)).map((a) => a.accessToken)).toEqual([null, null]);
});

async function deviceCode(clientId = APP_CLIENT_ID) {
  return post("/api/auth/device/code", { client_id: clientId });
}

// What the link page does with the code the player types.
async function approve(userCode: string, cookie: string) {
  await get(`/api/auth/device?user_code=${userCode}`, { cookie });
  return post("/api/auth/device/approve", { userCode }, { cookie });
}

test("a PC is linked by the code its app shows, approved by the signed-in player", async () => {
  const code = (await (await deviceCode()).json()) as { device_code: string; user_code: string; verification_uri: string };
  expect(code.verification_uri).toBe("http://localhost:3000/link");

  const tokenRequest = { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: code.device_code, client_id: APP_CLIENT_ID };
  const early = await post("/api/auth/device/token", tokenRequest);
  expect(await early.json()).toMatchObject({ error: "authorization_pending" });
  await db.update(deviceCodes).set({ lastPolledAt: null }); // the app waits between polls

  const cookie = await signIn();
  expect((await approve(code.user_code, cookie)).status).toBe(200);
  const { access_token } = (await (await post("/api/auth/device/token", tokenRequest)).json()) as { access_token: string };

  const linked = await app.handle(
    new Request("http://localhost:3000/v1/link?name=Desk&platform=windows", { method: "POST", headers: { authorization: `Bearer ${access_token}` } }),
  );
  const { token, pc, battletag } = (await linked.json()) as LinkResponse;
  expect(battletag).toBe("Ann#1234"); // the app shows who it is linked to
  const [device] = await db.select().from(devices).where(eq(devices.id, pc));
  expect(device).toMatchObject({ name: "Desk", platform: "windows" });
  expect((await get("/v1/check", { authorization: `Bearer ${token}` })).status).toBe(200);
  // The device sign-in's session is gone; only the PC token remains.
  expect(await db.select().from(session).where(eq(session.token, access_token))).toEqual([]);
});

test("linking needs the device sign-in's token: not a cookie, and not twice", async () => {
  const cookie = await signIn();
  const link = (headers: Record<string, string>) => app.handle(new Request("http://localhost:3000/v1/link", { method: "POST", headers }));
  expect((await link({})).status).toBe(401);
  expect((await link({ cookie })).status).toBe(401);

  const code = (await (await deviceCode()).json()) as { device_code: string; user_code: string };
  await approve(code.user_code, cookie);
  const tokenRequest = { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: code.device_code, client_id: APP_CLIENT_ID };
  const { access_token } = (await (await post("/api/auth/device/token", tokenRequest)).json()) as { access_token: string };
  expect((await get("/v1/check", { authorization: `Bearer ${access_token}` })).status).toBe(401); // a session is not a PC token
  expect((await link({ authorization: `Bearer ${access_token}` })).status).toBe(200);
  expect((await link({ authorization: `Bearer ${access_token}` })).status).toBe(401);
});

test("only the app may ask for a device code", async () => {
  expect((await deviceCode("something-else")).status).toBe(400);
});

test("the link page is served", async () => {
  const page = await get("/link");
  expect(page.headers.get("content-type")).toContain("text/html");
  const text = await page.text();
  expect(text).toContain("Link this PC");
  expect(text).toContain("Only continue if the Road to Sixty app on this computer opened this page");
});
