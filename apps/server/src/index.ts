import { app } from "./app";
import { config } from "./config";
import { migrateDb } from "./db";
import { MAX_PACKED } from "./storage";
import { startPrune } from "./prune";
import { startWorker } from "./worker";

await migrateDb();
startWorker();
startPrune(config.prune);
// Bun refuses a bigger body before reading it (413).
app.listen({ port: config.port, maxRequestBodySize: MAX_PACKED });
console.log(`Road to Sixty server on port ${config.port}`);
