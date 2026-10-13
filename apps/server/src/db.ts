import { SQL } from "bun";
import { drizzle } from "drizzle-orm/bun-sql";
import { migrate } from "drizzle-orm/bun-sql/migrator";
import { config } from "./config";
import * as schema from "./schema";

export const client = new SQL(config.databaseUrl);
export const db = drizzle({ client, schema });

export function migrateDb() {
  return migrate(db, { migrationsFolder: `${import.meta.dir}/../drizzle` });
}
