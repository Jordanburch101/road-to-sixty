import { SQL } from "bun";
import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/bun-sql";
import { migrate } from "drizzle-orm/bun-sql/migrator";
import { config } from "./config";
import * as schema from "./schema";

export const client = new SQL(config.databaseUrl);
export const db = drizzle({ client, schema });

type Tx = Parameters<Parameters<typeof db.transaction>[0]>[0];

// Taken around a player's journey file and the version row that needs it,
// until the transaction ends: by a merge or an upload storing a file (put
// skips one that is already there) and by the clean-up deleting files no
// row needs. Without it the clean-up could delete a file a merge had just
// reused for a new head, before that head's row was there to keep it, and
// every download of that head failed from then on (#112).
export async function lockFiles(tx: Tx, userId: string) {
  await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${`files:${userId}`}))`);
}

export function migrateDb() {
  return migrate(db, { migrationsFolder: `${import.meta.dir}/../drizzle` });
}
