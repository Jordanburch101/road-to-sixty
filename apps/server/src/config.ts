// Settings from the environment; .env.example lists them. Bun reads .env,
// and .env.test under bun test.

function env(name: string, fallback?: string): string {
  const value = process.env[name] || fallback;
  if (value === undefined) throw new Error(`${name} is not set`);
  return value;
}

// The daily clean-up: "dry" only logs what it would delete, so a deploy
// never deletes anything until someone has read that log and set "on".
export function pruneMode(value: string | undefined): "dry" | "on" | "off" {
  const mode = value || "dry";
  if (mode !== "dry" && mode !== "on" && mode !== "off") throw new Error(`PRUNE must be dry, on or off, not ${mode}`);
  return mode;
}

export const config = {
  port: Number(env("PORT", "3000")),
  databaseUrl: env("DATABASE_URL"),
  s3: {
    endpoint: env("S3_ENDPOINT"),
    bucket: env("S3_BUCKET"),
    accessKeyId: env("S3_ACCESS_KEY_ID"),
    secretAccessKey: env("S3_SECRET_ACCESS_KEY"),
  },
  auth: {
    // The server's own address, which Battle.net returns players to.
    url: env("BETTER_AUTH_URL"),
    secret: env("BETTER_AUTH_SECRET"),
    // Keys the hash of each Battle.net account ID. Never change it: every
    // player would come back as a new account.
    accountHashKey: env("ACCOUNT_HASH_KEY"),
  },
  battlenet: {
    url: env("BATTLENET_URL", "https://oauth.battle.net"),
    clientId: env("BATTLENET_CLIENT_ID"),
    clientSecret: env("BATTLENET_CLIENT_SECRET"),
  },
  prune: pruneMode(process.env.PRUNE),
  lua51: env("LUA51", "lua5.1"),
  luaDir: env("LUA_DIR", `${import.meta.dir}/../../addon/RoadToSixty`),
};
