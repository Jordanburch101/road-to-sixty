import { beforeAll, expect, test } from "bun:test";
import { client, migrateDb } from "../src/db";

beforeAll(migrateDb);

// Every request reads versions and jobs by these columns; without them each
// /check, upload, history and claim scans the whole table, and deleting an
// account checks each row against whole tables.
test("the tables that grow have indexes on the columns requests read them by", async () => {
  const rows = await client`SELECT indexname FROM pg_indexes WHERE schemaname = 'public'`;
  const names = rows.map((r: Record<string, unknown>) => String(r.indexname));
  for (const name of [
    "versions_character",
    "versions_device_upload",
    "jobs_due",
    "jobs_version",
    "jobs_character",
    "version_parents_parent",
    "devices_user",
    "versions_fingerprint",
    "session_user",
    "verification_identifier",
    "device_code_device_code_unique",
    "device_code_user_code_unique",
  ]) {
    expect(names).toContain(name);
  }
});
