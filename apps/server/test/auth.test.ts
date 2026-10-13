import { beforeEach, expect, test } from "bun:test";
import { app } from "../src/app";
import { accountHash } from "../src/auth";
import { db } from "../src/db";
import { account, user } from "../src/schema";
import { signIn } from "./battlenet";
import { reset } from "./helpers";

beforeEach(reset);

const get = (path: string, headers: Record<string, string> = {}) => app.handle(new Request(`http://localhost:3000${path}`, { headers }));

test("signing in with Battle.net makes a player named by BattleTag, keyed by a hash of the account ID", async () => {
  const cookie = await signIn({ id: 1234, battletag: "Ann#1234" });
  const signedIn = (await (await get("/api/auth/get-session", { cookie })).json()) as { user: { name: string } };
  expect(signedIn.user.name).toBe("Ann#1234");
  const [row] = await db.select().from(account);
  expect(row).toMatchObject({ providerId: "battlenet", accountId: accountHash(1234), accessToken: null, idToken: null });
  expect(JSON.stringify(await db.select().from(user))).not.toContain("1234@");
});

test("signing in again is the same player, with the BattleTag brought up to date", async () => {
  await signIn({ id: 1234, battletag: "Ann#1234" });
  await signIn({ id: 1234, battletag: "Annie#1234" });
  await signIn({ id: 5678, battletag: "Bob#5678" });
  const users = await db.select().from(user).orderBy(user.name);
  expect(users.map((u) => u.name)).toEqual(["Annie#1234", "Bob#5678"]);
  expect((await db.select().from(account)).map((a) => a.accessToken)).toEqual([null, null]);
});
