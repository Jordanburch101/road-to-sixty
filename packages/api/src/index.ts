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
  // The version to deliver, or null when it needs a newer addon than this PC has.
  version: number | null;
  fingerprint: string;
  replace: boolean; // a restore: the addon replaces instead of merging
  updateAddon: boolean;
};

export type CheckResponse = { characters: CheckEntry[] };

// GET /v1/versions/:id returns the journey as zstd-compressed Parse.Write
// text: what the app puts in data.lua's journey string, after decompressing.
