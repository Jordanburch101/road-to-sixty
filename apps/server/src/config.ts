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
  lua51: env("LUA51", "lua5.1"),
  luaDir: env("LUA_DIR", `${import.meta.dir}/../../addon/RoadToSixty`),
};
