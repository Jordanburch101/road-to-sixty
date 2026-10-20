// The app demo's story as a function of time, following the two tables in
// docs/superpowers/specs/2026-10-20-app-demo-design.md. `demoAt(t)` says what
// the window, the menu bar and the lines beside it show at second t; the demo
// component only draws it. The names and numbers are made up.

export type Part = "setup" | "arrive" | "level" | "new";
export type Line = { head: string; text: string };
export type Target = "icon" | "install" | "link" | "done";
export type Row = { name: string; cls: "WARRIOR" | "HUNTER" | "PALADIN" | "MAGE"; level: number; played: string; line: string; glow: boolean };
export type Step = "waiting" | "current" | "done";
export type Demo = {
  part: Part;
  open: boolean; // the window is showing, and the menu bar icon is lit
  clock: string; // "Tue 21:44"
  screen: "setup" | "characters";
  steps: [Step, Step, Step];
  installed: boolean; // step 1 reads "Addon installed" and the card "Addon 1.10.2"
  typed: string; // the name box, "" to "Desk"
  linked: boolean; // "Linked to Player#0000." shows
  cursor: { shown: boolean; at: Target; down: boolean };
  syncing: boolean; // the pill says "Syncing…" (else "Synced just now")
  pulse: number; // goes up by one each time the pill turns to synced, so the dot can pulse once
  rows: Row[]; // top to bottom
};

export const LOOP = 23;

export const LINES: Record<Part, { left: Line; right: Line }> = {
  setup: {
    left: { head: "Three clicks, once", text: "It finds WoW, puts the addon in, and links this PC to your Battle.net account." },
    right: { head: "In your menu bar or tray", text: "It opens under its icon and stays out of the way. Close the window and it keeps syncing." },
  },
  arrive: {
    left: { head: "Every character, every PC", text: "The ones you played on the laptop come down to this PC too." },
    right: { head: "Nothing to copy by hand", text: "It reads the addon's saved journeys itself." },
  },
  level: {
    left: { head: "Backed up after every session", text: "When you log out, it sends the journey up." },
    right: { head: "Ready before you log in", text: "When the game starts, it brings the newest one back." },
  },
  new: {
    left: { head: "New characters join by themselves", text: "Make one, play, log out, and it's on the list." },
    right: { head: "Free, with nothing to buy", text: "No subscription, no ads, no paid version." },
  },
};

export const STILL_LINES = {
  left: { head: "In your menu bar or tray", text: "It opens under its icon and stays out of the way. Close the window and it keeps syncing." },
  right: { head: "Backed up after every session", text: "When you log out, it sends the journey up. When the game starts, it brings the newest one back before you log in." },
};

const row = (name: string, cls: Row["cls"], level: number, played: string, line: string): Row => ({ name, cls, level, played, line, glow: false });

const MIRELLE = row("Mirelle", "HUNTER", 27, "3d 11h", "Classic PvE · Laptop, yesterday");
const BRANNOC = row("Brannoc", "PALADIN", 60, "18d 2h", "Classic PvE · Laptop, yesterday");

export const STILL: Demo = {
  part: "setup",
  open: true,
  clock: "Tue 21:44",
  screen: "characters",
  steps: ["done", "done", "done"],
  installed: true,
  typed: "Desk",
  linked: true,
  cursor: { shown: false, at: "done", down: false },
  syncing: false,
  pulse: 0,
  rows: [
    row("Thalrok", "WARRIOR", 42, "9d 4h", "Classic PvE · Desk, 2 min ago"),
    MIRELLE,
    BRANNOC,
    row("Ysolde", "MAGE", 12, "14h 20m", "Classic PvE · Desk, 3 days ago"),
  ],
};

const NAME = "Desk";
// When each letter of the name is typed.
const KEYS = [4.0, 4.2, 4.4, 4.6];
const CLICK_DOWN = 0.12;

// When the cursor starts gliding to each button; it clicks 0.6 s later.
const GLIDES: [number, Target][] = [
  [0.4, "icon"],
  [2.0, "install"],
  [5.2, "link"],
  [7.4, "done"],
];

export function demoAt(time: number, phone: boolean): Demo {
  const t = ((time % LOOP) + LOOP) % LOOP;

  const thalrok = row("Thalrok", "WARRIOR", 42, "9d 4h", "Classic PvE · Desk, just now");
  const d: Demo = {
    part: "setup",
    open: false,
    clock: "Tue 21:44",
    screen: "setup",
    steps: ["current", "waiting", "waiting"],
    installed: false,
    typed: "",
    linked: false,
    cursor: { shown: false, at: "icon", down: false },
    syncing: false,
    pulse: 0,
    rows: [],
  };

  if (t >= 1.0) d.open = true;
  if (t >= 2.8) {
    d.installed = true;
    d.steps = ["done", "waiting", "waiting"];
  }
  if (t >= 3.8) d.steps = ["done", "current", "waiting"];
  d.typed = NAME.slice(0, KEYS.filter((k) => t >= k).length);
  if (t >= 6.0) {
    d.linked = true;
    d.steps = ["done", "done", "waiting"];
  }
  if (t >= 6.6) d.steps = ["done", "done", "current"];
  if (t >= 8.0) {
    d.screen = "characters";
    d.part = "arrive";
    d.syncing = true;
  }
  if (t >= 9.2) d.rows.push(thalrok);
  if (t >= 9.7) d.rows.push(MIRELLE);
  if (t >= 10.2) d.rows.push(BRANNOC);
  if (t >= 11.0) {
    d.syncing = false;
    d.pulse = 1;
  }
  if (t >= 12.5) {
    d.part = "level";
    d.clock = "Tue 23:12";
    d.syncing = true;
  }
  if (t >= 13.3) {
    thalrok.level = 43;
    thalrok.played = "9d 6h";
  }
  thalrok.glow = t >= 13.3 && t < 14.5;
  if (t >= 14.3) {
    d.syncing = false;
    d.pulse = 2;
  }
  if (t >= 16.0) {
    d.part = "new";
    d.clock = "Wed 19:30";
    d.syncing = true;
  }
  if (t >= 16.6) {
    thalrok.line = "Classic PvE · Desk, 20 h ago";
    const ysolde = row("Ysolde", "MAGE", 1, "12m", "Classic PvE · Desk, just now");
    ysolde.glow = t < 17.8;
    d.rows.unshift(ysolde);
  }
  if (t >= 17.6) {
    d.syncing = false;
    d.pulse = 3;
  }
  if (t >= 22.0) d.open = false;
  if (t >= 22.5) d.clock = "Tue 21:44";

  for (const [start, at] of GLIDES) {
    if (t < start) break;
    d.cursor.at = at;
    d.cursor.shown = !phone || at !== "icon";
    d.cursor.down = d.cursor.shown && t >= start + 0.6 && t < start + 0.6 + CLICK_DOWN;
  }
  if (t >= 8.0 + CLICK_DOWN) d.cursor.shown = false;

  return d;
}

// The first loop starts just after the window has opened, so the still
// picture slides straight to the setup screen. Starting at 0 would close the
// window and leave the section empty for two seconds as it comes into view.
export const START = 1.2;
// How long the still rows stay, while their screen slides away.
const LEAVING = 0.6;

export function firstAt(t: number, phone: boolean): Demo {
  const d = demoAt(t, phone);
  return t < START + LEAVING ? { ...d, rows: STILL.rows } : d;
}

export function advance(t: number, frameMs: number): number {
  return t + Math.min(frameMs, 100) / 1000;
}
