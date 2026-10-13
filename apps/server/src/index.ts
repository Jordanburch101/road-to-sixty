import { app } from "./app";
import { config } from "./config";
import { migrateDb } from "./db";
import { startWorker } from "./worker";

await migrateDb();
startWorker();
// 32 MB uncompressed is the most an upload may hold; compressed it is smaller.
app.listen({ port: config.port, maxRequestBodySize: 33 * 1024 * 1024 });
console.log(`Road to Sixty server on port ${config.port}`);
