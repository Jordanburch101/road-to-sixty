import { expect, test } from "bun:test";
import type { CharacterInfo, DeviceInfo, VersionInfo } from "@road-to-sixty/api";
import type { Folder } from "./api";
import { BETA, ago, folderWords, gameName, installFolder, isTest, testJourneys, testWords, byGame, characterLine, deviceLine, earlierLine, earlierOf, played, realmName, removeWords, titleLine, updateWords, versionLine, when } from "./format";

const now = new Date(2026, 9, 15, 22, 0);
const at = (...parts: [number, number, number, number, number]) => new Date(...parts).toISOString();

test("time played reads as the biggest two units", () => {
  expect(played(9 * 86400 + 4 * 3600 + 59)).toBe("9d 4h");
  expect(played(4 * 3600 + 12 * 60)).toBe("4h 12m");
  expect(played(35 * 60)).toBe("35m");
  expect(played(null)).toBe("");
});

test("ago reads like the tray line", () => {
  expect(ago(at(2026, 9, 15, 21, 58), now)).toBe("2 min ago");
  expect(ago(at(2026, 9, 14, 20, 0), now)).toBe("yesterday");
  expect(ago(at(2026, 9, 12, 20, 0), now)).toBe("3 days ago");
});

test("a version's time says today, yesterday or the date", () => {
  expect(when(at(2026, 9, 15, 21, 44), now)).toBe("Today, 21:44");
  expect(when(at(2026, 9, 14, 22, 18), now)).toBe("Yesterday, 22:18");
  expect(when(at(2026, 9, 3, 20, 41), now)).toBe("3 Oct, 20:41");
  expect(when(at(2025, 9, 3, 20, 41), now)).toBe("3 Oct 2025, 20:41");
});

const ann: CharacterInfo = {
  id: 1, game: "_classic_beta_", realm: "Classic Beta PvE 2", name: "Ann", class: "WARRIOR", level: 42,
  played: 3600, lastPlayedAt: null, syncedAt: at(2026, 9, 14, 20, 0), syncedFrom: "Laptop", earlier: false,
};

test("a character's lines: realm, PC and when; on its page class, realm and time played", () => {
  expect(titleLine({ ...ann, realm: "CAMWOW AU1 Realm 1 PvE", played: 37 * 3600 })).toBe("Warrior · Normal · 1d 13h played");
  expect(titleLine({ class: null, realm: "Nightslayer", played: null })).toBe("Nightslayer");
  expect(characterLine(ann, now)).toBe("Classic Beta PvE 2 · Laptop, yesterday");
  expect(characterLine({ ...ann, syncedFrom: null }, now)).toBe("Classic Beta PvE 2 · restored yesterday");
  expect(characterLine({ ...ann, realm: "CAMWOW AU1 Realm 1 PvE" }, now)).toBe("Normal · Laptop, yesterday");
});

test("Forever's realms read as their type, other realms as their name", () => {
  expect(realmName("CAMWOW AU1 Realm 1 PvE")).toBe("Normal");
  expect(realmName("CAMWOW US1 Realm 2 PvP")).toBe("PvP");
  expect(realmName("CAMWOW US2 Realm 11 RP")).toBe("RP");
  expect(realmName("CAMWOW US1 Realm 9 RP PvP")).toBe("RP-PvP");
  expect(realmName("CAMWOW EU5 Realm 6 Something New")).toBe("CAMWOW EU5 Realm 6 Something New");
  expect(realmName("Nightslayer")).toBe("Nightslayer");
  expect(realmName("Classic Beta PvP")).toBe("Classic Beta PvP");
  expect(realmName("CAMWOW EU5 Realm 6 constructor")).toBe("CAMWOW EU5 Realm 6 constructor");
});

test("a history entry says where it came from", () => {
  const v: VersionInfo = { id: 7, kind: "merged", createdAt: at(2026, 9, 15, 19, 2), level: 41, from: "Laptop", restoredFrom: null, current: false };
  expect(versionLine(v, now)).toBe("From Laptop · level 41");
  expect(versionLine({ ...v, kind: "restore", from: null, restoredFrom: { id: 3, createdAt: at(2026, 9, 2, 23, 5) } }, now)).toBe("Restored to 2 Oct, 23:05 · level 41");
});

test("a PC's line names its platform, versions and when it was seen", () => {
  const d: DeviceInfo = { id: "pc-1", name: "Desk", platform: "darwin", appVersion: "0.1.2", addonVersion: "1.9.0", lastSeenAt: now.toISOString() };
  expect(deviceLine(d, now)).toBe("Mac · app 0.1.2 · addon 1.9.0 · now");
  expect(deviceLine({ ...d, platform: "windows", appVersion: null, lastSeenAt: null }, now)).toBe("Windows · addon 1.9.0 · never seen");
});

test("the update row says what the update is doing", () => {
  expect(updateWords({ state: "ready", version: "0.1.3" }, undefined)).toBe("Version 0.1.3 is ready. It installs when you close this window.");
  expect(updateWords({ state: "none" }, null)).toBe("Up to date. Updates install by themselves while the window is closed.");
  expect(updateWords({ state: "none" }, "0.1.3")).toBe("Version 0.1.3 is downloading. It installs when you close this window.");
  expect(updateWords({ state: "failed", why: "no network" }, undefined)).toBe("Couldn't update: no network. It tries again in a few hours.");
});

test("beta and stress test characters are listed apart, by the server's row for each", () => {
  const forever = { ...ann, game: "_forever_", realm: "CAMWOW AU1 Realm 1 PvE" };
  const info = new Map([
    ["Ann-Classic Beta PvE 2", ann],
    ["Bob-Nightslayer", { ...ann, id: 2, name: "Bob", realm: "Nightslayer", game: "_classic_" }],
    // The beta's characters came along into _forever_ at launch.
    ["Di-Classic Beta PvP", { ...forever, id: 3, name: "Di", realm: "Classic Beta PvP", lastPlayedAt: "2026-10-23T04:11:58Z" }],
    // Played on the stress test, on a realm named like a live one.
    ["Ed-CAMWOW AU1 Realm 1 PvE", { ...forever, id: 4, name: "Ed", lastPlayedAt: "2026-10-28T10:00:00Z" }],
    ["Flo-CAMWOW AU1 Realm 1 PvE", { ...forever, id: 5, name: "Flo", lastPlayedAt: "2026-11-04T23:35:21Z" }],
    ["Gus-CAMWOW AU1 Realm 1 PvE", { ...forever, id: 6, name: "Gus", lastPlayedAt: null }],
  ]);
  const rows = [...info.keys(), "Cy-Nightslayer"].map((key) => ({ key }));
  const { main, test } = byGame(rows, info);
  expect(main.map((r) => r.key)).toEqual(["Bob-Nightslayer", "Flo-CAMWOW AU1 Realm 1 PvE", "Gus-CAMWOW AU1 Realm 1 PvE", "Cy-Nightslayer"]);
  expect(test.map((r) => r.key)).toEqual(["Ann-Classic Beta PvE 2", "Di-Classic Beta PvP", "Ed-CAMWOW AU1 Realm 1 PvE"]);
  expect(isTest({ ...ann, game: "_anniversary_", lastPlayedAt: "2026-10-01T00:00:00Z" })).toBe(false);
  expect(BETA).toBe("_classic_beta_");
  expect(testWords(1)).toBe("Remove 1 beta and stress test character from the backup, earlier journeys included? Journeys on your PCs stay.");
  expect(testWords(3)).toBe("Remove 3 beta and stress test characters from the backup, earlier journeys included? Journeys on your PCs stay.");
});

test("Remove all takes every journey of a test character, oldest first, and leaves live ones", () => {
  const forever = { ...ann, game: "_forever_", realm: "CAMWOW AU1 Realm 1 PvE" };
  const stress = { ...forever, id: 9, name: "Ed", lastPlayedAt: "2026-10-28T10:00:00Z" };
  // An earlier journey with no last-played time: not test by itself, but the
  // server would refuse to remove Ed's current one while it is left.
  const stressEarlier = { ...stress, id: 4, earlier: true, lastPlayedAt: null };
  const live = { ...forever, id: 8, name: "Flo", lastPlayedAt: "2026-11-05T01:00:00Z" };
  // A live character's earlier test journey stays for its History.
  const liveEarlier = { ...live, id: 3, earlier: true, lastPlayedAt: "2026-10-20T10:00:00Z" };
  const { characters, journeys } = testJourneys([stress, live, ann, stressEarlier, liveEarlier]);
  expect(characters).toBe(2);
  expect(journeys.map((c) => c.id)).toEqual([1, 4, 9]);
});

test("a character's earlier journeys are its name's, newest first", () => {
  const old = { ...ann, id: 3, earlier: true, level: 12, lastPlayedAt: at(2026, 9, 12, 20, 0) };
  const older = { ...ann, id: 2, earlier: true, level: null, lastPlayedAt: null };
  const otherName = { ...ann, id: 4, name: "Bob", earlier: true };
  expect(earlierOf([ann, older, otherName, old], ann)).toEqual([old, older]);
  expect(earlierLine(old, now)).toBe("Level 12 · last played 3 days ago");
  expect(earlierLine(older, now)).toBe("");
});

test("removing says what stays", () => {
  expect(removeWords("Ann")).toBe(
    "Removes Ann's journey from the backup. Journeys on your PCs stay. If you play Ann again, its journey is backed up again from that PC.",
  );
});

test("a game folder reads as words, with its install folder and addon apart", () => {
  expect(gameName("_classic_beta_")).toBe("Classic Beta");
  expect(gameName("_classic_")).toBe("Classic");
  expect(gameName("_classic_ptr_")).toBe("Classic PTR");
  expect(installFolder("/Applications/World of Warcraft/_classic_beta_", "_classic_beta_")).toBe("/Applications/World of Warcraft");
  expect(installFolder("D:\\Games\\World of Warcraft\\_classic_", "_classic_")).toBe("D:\\Games\\World of Warcraft");
});

test("each game folder's addon state reads as the mockups do", () => {
  const base = { path: "/wow/_classic_beta_", name: "_classic_beta_", characters: 3, addon: "1.10.1", updatedAt: null } as const;
  const day = 86400;
  const words = (f: Folder) => folderWords(f, 10 * day);
  expect(words({ ...base, state: "current" })).toEqual({ line: "Addon 1.10.1", warn: false, action: null });
  expect(words({ ...base, state: "current", updatedAt: 10 * day - 3600 }).line).toBe("Addon 1.10.1 · updated today");
  expect(words({ ...base, addon: "1.10.0", state: "waiting", latest: "1.10.1" }).line).toBe("Addon 1.10.0 · 1.10.1 installs when WoW closes");
  expect(words({ ...base, addon: null, state: "missing", latest: "1.10.1" })).toEqual({ line: "No addon yet", warn: false, action: "install" });
  expect(words({ ...base, addon: null, state: "developer" }).line).toBe("Developer addon · the app leaves it alone");
  expect(words({ ...base, state: "failed", why: "the disk is full" })).toEqual({
    line: "Couldn't update the addon: the disk is full. Trying again in a few hours.",
    warn: true,
    action: null,
  });
  expect(words({ ...base, addon: "1.10.0", state: "behind", latest: "1.10.1" })).toEqual({ line: "Addon 1.10.0 · 1.10.1 is out", warn: false, action: "update" });
  expect(words({ ...base, state: "otherClient" }).line).toBe("Addon 1.10.1 · not for this version of WoW");
});
