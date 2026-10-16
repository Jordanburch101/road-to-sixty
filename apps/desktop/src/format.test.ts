import { expect, test } from "bun:test";
import type { CharacterInfo, DeviceInfo, VersionInfo } from "@road-to-sixty/api";
import { BETA, addonLine, ago, gameName, installFolder, betaWords, byGame, characterLine, deviceLine, earlierLine, earlierOf, levelClass, played, removeWords, updateWords, versionLine, when } from "./format";

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

test("a character's lines: level and class, then realm, PC and when", () => {
  expect(levelClass(ann)).toBe("Level 42 Warrior");
  expect(levelClass({ level: null, class: null })).toBe("");
  expect(characterLine(ann, now)).toBe("Classic Beta PvE 2 · Laptop, yesterday");
  expect(characterLine({ ...ann, syncedFrom: null }, now)).toBe("Classic Beta PvE 2 · restored yesterday");
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

test("beta characters are listed apart, by the server's game for each", () => {
  const info = new Map([
    ["Ann-Classic Beta PvE 2", ann],
    ["Bob-Nightslayer", { ...ann, id: 2, name: "Bob", realm: "Nightslayer", game: "_classic_" }],
  ]);
  const rows = [{ key: "Ann-Classic Beta PvE 2" }, { key: "Bob-Nightslayer" }, { key: "Cy-Nightslayer" }];
  expect(byGame(rows, info)).toEqual({ main: [rows[1]!, rows[2]!], beta: [rows[0]!] });
  expect(BETA).toBe("_classic_beta_");
  expect(betaWords(1)).toBe("Remove 1 beta journey from the backup? Journeys on your PCs stay.");
  expect(betaWords(3)).toBe("Remove 3 beta journeys from the backup? Journeys on your PCs stay.");
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
  expect(addonLine("1.10.0")).toBe("Addon 1.10.0");
  expect(addonLine(null)).toBe("Developer addon");
});
