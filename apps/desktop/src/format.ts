// The words and numbers the screens show, as plain functions so they are
// tested without a window.
import type { CharacterInfo, DeviceInfo, VersionInfo } from "@road-to-sixty/api";
import type { Folder, Update } from "./api";

// The game's class colours (RAID_CLASS_COLORS).
export const CLASSES: Record<string, { name: string; colour: string }> = {
  WARRIOR: { name: "Warrior", colour: "#c69b6d" },
  PALADIN: { name: "Paladin", colour: "#f48cba" },
  HUNTER: { name: "Hunter", colour: "#aad372" },
  ROGUE: { name: "Rogue", colour: "#fff468" },
  PRIEST: { name: "Priest", colour: "#ffffff" },
  SHAMAN: { name: "Shaman", colour: "#0070dd" },
  MAGE: { name: "Mage", colour: "#3fc7eb" },
  WARLOCK: { name: "Warlock", colour: "#8788ee" },
  DRUID: { name: "Druid", colour: "#ff7c0a" },
};

// Time played in its two biggest units, as the game's /played does.
export function played(seconds: number | null): string {
  if (seconds === null) return "";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// As the tray line says it (status.rs, ago).
export function ago(iso: string, now: Date): string {
  const s = Math.max(0, (now.getTime() - Date.parse(iso)) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 172800) return "yesterday";
  return `${Math.floor(s / 86400)} days ago`;
}

// A version's time in this PC's time zone: "Today, 21:44", "3 Oct, 20:41".
export function when(iso: string, now: Date): string {
  const t = new Date(iso);
  const time = t.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(now) - day(t)) / 86400000);
  if (days === 0) return `Today, ${time}`;
  if (days === 1) return `Yesterday, ${time}`;
  const year = t.getFullYear() === now.getFullYear() ? {} : { year: "numeric" as const };
  return `${t.toLocaleDateString("en-GB", { day: "numeric", month: "short", ...year })}, ${time}`;
}

export function levelClass(c: { level: number | null; class: string | null }): string {
  return [c.level !== null ? `Level ${c.level}` : "", c.class ? (CLASSES[c.class]?.name ?? "") : ""].filter(Boolean).join(" ");
}

// Under a character's name: its realm, and which PC last backed it up, when.
export function characterLine(c: CharacterInfo, now: Date): string {
  const by = c.syncedFrom ? `${c.syncedFrom}, ${ago(c.syncedAt, now)}` : `restored ${ago(c.syncedAt, now)}`;
  return `${c.realm} · ${by}`;
}

export function versionLine(v: VersionInfo, now: Date): string {
  const what =
    v.kind === "restore" ? (v.restoredFrom ? `Restored to ${when(v.restoredFrom.createdAt, now)}` : "Restored") : v.from ? `From ${v.from}` : "Merged";
  return v.level !== null ? `${what} · level ${v.level}` : what;
}

const PLATFORMS: Record<string, string> = { darwin: "Mac", windows: "Windows", linux: "Linux" };

export function deviceLine(d: DeviceInfo, now: Date): string {
  const seen = d.lastSeenAt ? ago(d.lastSeenAt, now).replace("just now", "now") : "never seen";
  return [d.platform ? (PLATFORMS[d.platform] ?? d.platform) : "", d.appVersion ? `app ${d.appVersion}` : "", d.addonVersion ? `addon ${d.addonVersion}` : "", seen]
    .filter(Boolean)
    .join(" · ");
}

// checked: what "Check now" found (undefined before it is pressed, null for nothing newer).
export function updateWords(update: Update, checked: string | null | undefined): string {
  if (update.state === "ready") return `Version ${update.version} is ready. It installs when you close this window.`;
  if (update.state === "failed") return `Couldn't update: ${update.why}. It tries again in a few hours.`;
  if (checked) return `Version ${checked} is downloading. It installs when you close this window.`;
  const auto = "Updates install by themselves while the window is closed.";
  if (update.state === "updated") return `Updated to ${update.version}. ${auto}`;
  return checked === null ? `Up to date. ${auto}` : auto;
}

// The beta's game folder: its characters are tagged and removed together.
export const BETA = "_classic_beta_";

// The list's rows, this game's first and the beta's apart, by the server's
// game for each. A row the server doesn't have stays in the main list.
export function byGame<T extends { key: string }>(rows: T[], info: Map<string, CharacterInfo>): { main: T[]; beta: T[] } {
  const beta = rows.filter((r) => info.get(r.key)?.game === BETA);
  return { main: rows.filter((r) => !beta.includes(r)), beta };
}

export const betaWords = (n: number) => `Remove ${n} beta ${n === 1 ? "journey" : "journeys"} from the backup? Journeys on your PCs stay.`;

// A character's earlier journeys: the same game, realm and name, newest first.
export function earlierOf(all: CharacterInfo[], c: CharacterInfo): CharacterInfo[] {
  return all.filter((e) => e.earlier && e.game === c.game && e.realm === c.realm && e.name === c.name).sort((a, b) => b.id - a.id);
}

export function earlierLine(c: CharacterInfo, now: Date): string {
  return [c.level !== null ? `Level ${c.level}` : "", c.lastPlayedAt ? `last played ${ago(c.lastPlayedAt, now)}` : ""].filter(Boolean).join(" · ");
}

export const removeWords = (name: string) =>
  `Removes ${name}'s journey from the backup. Journeys on your PCs stay. If you play ${name} again, its journey is backed up again from that PC.`;

// A game folder's name in words: _classic_beta_ is "Classic Beta", so
// whatever folder Forever launches in reads properly.
export function gameName(folder: string): string {
  return folder
    .split("_")
    .filter(Boolean)
    .map((w) => (w === "ptr" ? "PTR" : w[0]!.toUpperCase() + w.slice(1)))
    .join(" ");
}

// The install a game folder is in: its path without the folder's own name.
export function installFolder(path: string, folder: string): string {
  return path.endsWith(folder) ? path.slice(0, -folder.length).replace(/[\\/]+$/, "") : path;
}

// A game folder's addon line. now and updatedAt are Unix seconds.
export function folderWords(f: Folder, now: number): { line: string; warn: boolean; action: "install" | "update" | null } {
  const has = `Addon ${f.addon ?? ""}`;
  switch (f.state) {
    case "current":
      return { line: f.updatedAt !== null && now - f.updatedAt < 86400 ? `${has} · updated today` : has, warn: false, action: null };
    case "waiting":
      return { line: `${has} · ${f.latest} installs when WoW closes`, warn: false, action: null };
    case "missing":
      return { line: "No addon yet", warn: false, action: "install" };
    case "developer":
      return { line: "Developer addon · the app leaves it alone", warn: false, action: null };
    case "failed":
      return { line: `Couldn't update the addon: ${f.why}. Trying again in a few hours.`, warn: true, action: null };
    case "behind":
      return { line: `${has} · ${f.latest} is out`, warn: false, action: "update" };
    case "otherClient":
      return { line: `${has} · not for this version of WoW`, warn: false, action: null };
  }
}
