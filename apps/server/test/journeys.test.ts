// One journey per character (spec 2026-10-15, journeys): stamps, which row
// an upload goes to, current and earlier journeys, removing a character.
// GUIDs here are made up.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { db } from "../src/db";
import { characters } from "../src/schema";
import { CHAR, addUser, reset } from "./helpers";

beforeEach(reset);
afterEach(() => mock.restore());

test("a name holds several journeys but only one from before stamps", async () => {
  const userId = await addUser("user-1");
  const row = (journey: string | null) => ({ userId, ...CHAR, journey });
  await db.insert(characters).values([row(null), row("Player-1-0A:0"), row("Player-1-0A:7000")]);
  await expect(db.insert(characters).values(row(null)).execute()).rejects.toThrow();
  await expect(db.insert(characters).values(row("Player-1-0A:0")).execute()).rejects.toThrow();
});
