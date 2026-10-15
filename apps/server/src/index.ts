import { app } from "./app";
import { config } from "./config";
import { migrateDb } from "./db";
import { MAX_PACKED } from "./storage";
import { startWorker } from "./worker";

await migrateDb();
startWorker();
// Bun refuses a bigger body before reading it (413).
app.listen({ port: config.port, maxRequestBodySize: MAX_PACKED });
console.log(`Road to Sixty server on port ${config.port}`);
