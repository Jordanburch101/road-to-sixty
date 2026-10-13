// Settings from the environment; .env.example lists them. Bun reads .env,
// and .env.test under bun test.

function env(name: string, fallback?: string): string {
  const value = process.env[name] || fallback;
  if (value === undefined) throw new Error(`${name} is not set`);
  return value;
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
  lua51: env("LUA51", "lua5.1"),
  luaDir: env("LUA_DIR", `${import.meta.dir}/../../addon/RoadToSixty`),
};
