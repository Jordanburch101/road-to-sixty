// Links a PC by hand until sign-in exists: prints its token once.
//   bun scripts/new-device.ts <user id> <PC name>
import { client } from "../src/db";
import { newDevice } from "../src/devices";

const [userId, name] = process.argv.slice(2);
if (!userId || !name) throw new Error("usage: bun scripts/new-device.ts <user id> <PC name>");
const { device, token } = await newDevice(userId, name);
console.log(`PC ${device.id} for ${userId}. Its token, shown only now:\n${token}`);
await client.close();
