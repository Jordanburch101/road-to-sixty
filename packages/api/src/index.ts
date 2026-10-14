// What the sync API sends and receives, shared by the server, the website
// and the app's window. The app's Rust side mirrors these by hand.

// The desktop app's client ID for Better Auth's device sign-in
// (/api/auth/device/code); the server accepts no other.
export const APP_CLIENT_ID = "road-to-sixty-app";

// POST /v1/link?name=&platform=, with the access token Better Auth's device
// sign-in gave the app (/api/auth/device/token) as Authorization: Bearer.
// That session ends; the app keeps the PC token instead.
export type LinkResponse = {
  token: string; // the PC token, for Authorization: Bearer on every /v1 call
  pc: string; // this PC's ID, which the addon keeps its counts under
  battletag: string; // who the PC is now linked to, for the app to show
};

// POST /v1/upload?game=&realm=&name=&addon=&received=, body: the character's
// SavedVariables file compressed with zstd.
export type UploadQuery = {
  game: string; // the game folder, such as _classic_beta_
  realm: string;
  name: string;
  addon?: string; // the addon version that wrote the file
  // The last version this PC received, by id. Not by fingerprint: a
  // restore holds the same text as the version it restores.
  received?: string;
};

export type UploadResponse = {
  version: number;
  // queued: stored and waiting to be merged; known: this exact file was
  // uploaded before, so nothing new happened.
  status: "queued" | "known";
};

// GET /v1/check
export type CheckEntry = {
  game: string;
  realm: string;
  name: string;
  // The version to deliver, or null when it needs a newer addon than this PC
  // has, or when the character has no merged version yet.
  version: number | null;
  fingerprint: string;
  // The newest restore, while this PC hasn't shown (by an upload's received)
  // that its addon took it in. The addon replaces its copy only when the
  // version it last brought in is older than this, so play since stays.
  restore: number | null;
  replace: boolean; // restore !== null; read by app 0.1.1
  updateAddon: boolean;
  // Why the server refused this PC's newest upload of this character, or
  // null. The app shows it against the character until a newer upload goes in.
  rejected: string | null;
};

export type CheckResponse = { characters: CheckEntry[] };

// GET /v1/versions/:id returns the journey as zstd-compressed Parse.Write
// text: what the app puts in data.lua's journey string, after decompressing.

// The account API: the app's window, with the PC token. Times are ISO 8601.

// GET /v1/characters: each character with a merged journey.
export type CharacterInfo = {
  id: number;
  game: string;
  realm: string;
  name: string;
  class: string | null; // the class file name, such as WARRIOR
  level: number | null;
  played: number | null; // seconds
  lastPlayedAt: string | null;
  syncedAt: string; // when its current version was made
  syncedFrom: string | null; // the PC whose upload made it; null for a restore
};

// GET /v1/characters/:id/versions: newest first, at most 100.
export type VersionInfo = {
  id: number;
  kind: "merged" | "restore";
  createdAt: string;
  level: number | null;
  from: string | null; // the PC whose upload made a merged version
  restoredFrom: { id: number; createdAt: string } | null;
  current: boolean;
};

// POST /v1/characters/:id/restore, body { version }: the version becomes
// current again as a new restore version; every PC replaces its copy with
// it at its next login, unless it already took the restore in.
export type RestoreResponse = { version: number };

// GET /v1/devices: the player's linked PCs, most recently seen first.
// PATCH /v1/devices/:id, body { name }, renames one; DELETE unlinks it.
export type DeviceInfo = {
  id: string; // the app compares it with its own pc to mark "This PC"
  name: string;
  platform: string | null; // darwin, windows or linux
  appVersion: string | null;
  addonVersion: string | null;
  lastSeenAt: string | null;
};
