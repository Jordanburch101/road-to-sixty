import { expect, test } from "bun:test";
import { advance, demoAt, LINES, LOOP, STILL, STILL_LINES } from "./demo";

const names = (t: number) => demoAt(t, false).rows.map((r) => r.name);

test("the lines are the spec's words", () => {
  expect(LINES).toEqual({
    setup: {
      left: { head: "Three clicks, once.", text: "It finds WoW, puts the addon in, and links this PC to your Battle.net account." },
      right: { head: "In your menu bar or tray.", text: "It opens under its icon and stays out of the way. Close the window and it keeps syncing." },
    },
    arrive: {
      left: { head: "Every character, every PC.", text: "The ones you played on the laptop come down to this PC too." },
      right: { head: "Nothing to copy by hand.", text: "It reads the addon's saved journeys itself." },
    },
    level: {
      left: { head: "Backed up after every session.", text: "When you log out, it sends the journey up." },
      right: { head: "Ready before you log in.", text: "When the game starts, it brings the newest one back." },
    },
    new: {
      left: { head: "New characters join by themselves.", text: "Make one, play, log out, and it's on the list." },
      right: { head: "Free, with nothing to buy.", text: "No subscription, no ads, no paid version." },
    },
  });
  expect(STILL_LINES).toEqual({
    left: { head: "In your menu bar or tray", text: "It opens under its icon and stays out of the way. Close the window and it keeps syncing." },
    right: { head: "Backed up after every session", text: "When you log out, it sends the journey up. When the game starts, it brings the newest one back before you log in." },
  });
});

test("the still picture is today's", () => {
  expect(STILL.open).toBe(true);
  expect(STILL.lit).toBe(true);
  expect(STILL.screen).toBe("characters");
  expect(STILL.syncing).toBe(false);
  expect(STILL.rows.map((r) => r.name)).toEqual(["Thalrok", "Mirelle", "Brannoc", "Ysolde"]);
  const ysolde = STILL.rows[3];
  expect(ysolde?.level).toBe(12);
  expect(ysolde?.played).toBe("14h");
});

test("the loop starts closed and unlit", () => {
  const d = demoAt(0, false);
  expect(d.open).toBe(false);
  expect(d.lit).toBe(false);
  expect(d.clock).toBe("Tue 21:44");
  expect(d.part).toBe("setup");
});

test("the window opens on step one", () => {
  const d = demoAt(1.5, false);
  expect(d.open).toBe(true);
  expect(d.lit).toBe(true);
  expect(d.screen).toBe("setup");
  expect(d.steps).toEqual(["current", "waiting", "waiting"]);
  expect(d.installed).toBe(false);
});

test("install ticks step one", () => {
  const d = demoAt(3.0, false);
  expect(d.installed).toBe(true);
  expect(d.steps[0]).toBe("done");
});

test("the name types itself in", () => {
  expect(demoAt(3.8, false).typed).toBe("");
  const part = demoAt(4.2, false).typed;
  expect(part.length).toBeGreaterThan(0);
  expect(part).not.toBe("Desk");
  expect("Desk".startsWith(part)).toBe(true);
  expect(demoAt(5.0, false).typed).toBe("Desk");
});

test("linking ticks step two and skips the browser", () => {
  const d = demoAt(6.2, false);
  expect(d.linked).toBe(true);
  expect(d.steps).toEqual(["done", "done", "waiting"]);
  expect(demoAt(6.8, false).steps[2]).toBe("current");
});

test("done moves to the characters", () => {
  const d = demoAt(8.2, false);
  expect(d.screen).toBe("characters");
  expect(d.rows).toEqual([]);
  expect(d.syncing).toBe(true);
  expect(d.part).toBe("arrive");
  expect(d.cursor.shown).toBe(false);
});

test("characters arrive one by one", () => {
  expect([9.0, 9.3, 9.8, 10.3].map((t) => demoAt(t, false).rows.length)).toEqual([0, 1, 2, 3]);
  expect(names(10.3)).toEqual(["Thalrok", "Mirelle", "Brannoc"]);
  expect(demoAt(11.2, false).syncing).toBe(false);
});

test("a session levels Thalrok up", () => {
  const before = demoAt(12.6, false);
  expect(before.clock).toBe("Tue 23:12");
  expect(before.part).toBe("level");
  expect(before.syncing).toBe(true);
  const thalrok = demoAt(13.5, false).rows[0];
  expect(thalrok?.level).toBe(43);
  expect(thalrok?.played).toBe("9d 6h");
  expect(thalrok?.glow).toBe(true);
  const after = demoAt(15.0, false);
  expect(after.rows.some((r) => r.glow)).toBe(false);
  expect(after.syncing).toBe(false);
});

test("a new character joins at the top", () => {
  const d = demoAt(16.8, false);
  expect(d.clock).toBe("Wed 19:30");
  expect(d.part).toBe("new");
  expect(d.rows[0]).toMatchObject({ name: "Ysolde", level: 1, played: "12m", line: "Classic PvE · Desk, just now" });
  expect(d.rows[1]).toMatchObject({ name: "Thalrok", line: "Classic PvE · Desk, yesterday" });
});

test("the loop ends closed and wraps", () => {
  expect(demoAt(22.5, false).open).toBe(false);
  expect(demoAt(LOOP + 1.5, false)).toEqual(demoAt(1.5, false));
});

test("the pill pulses once per sync", () => {
  for (const t of [11.0, 14.3, 17.6]) {
    expect(demoAt(t + 0.1, false).pulse - demoAt(t - 0.1, false).pulse).toBe(1);
    expect(demoAt(t - 0.1, false).syncing).toBe(true);
    expect(demoAt(t + 0.1, false).syncing).toBe(false);
  }
});

test("phones skip the icon click", () => {
  expect(demoAt(0.6, true).cursor.shown).toBe(false);
  expect(demoAt(1.5, true).open).toBe(true);
});

test("a long gap between frames moves the clock at most 0.1 s", () => {
  expect(advance(5, 16)).toBeCloseTo(5.016, 6);
  expect(advance(5, 4000)).toBeCloseTo(5.1, 6);
});
