// Uploads a made-up journey as a linked PC, waits for the merge and
// downloads it, to try a running server end to end. The character is
// "Scripttest" on "Script Realm"; remove it once the website can.
//   bun scripts/try-upload.ts <server URL> <PC token>
import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { zstdDecompressSync } from "node:zlib";

const [server, token] = process.argv.slice(2);
if (!server || !token) throw new Error("usage: bun scripts/try-upload.ts <server URL> <PC token>");
const auth = { authorization: `Bearer ${token}` };
const who = { game: "_classic_beta_", realm: "Script Realm", name: "Scripttest" };

const t = Math.floor(Date.now() / 1000);
const file = `RoadToSixtyCharDB = {["version"] = 3, ["events"] = {{${t}, "on", 0, 0, 0, 10}, {${t + 60}, "off", 0, 0, 0}}}`;
const query = new URLSearchParams({ ...who, addon: "script" });
const upload = await fetch(`${server}/v1/upload?${query}`, { method: "POST", headers: auth, body: Bun.zstdCompressSync(file) });
console.log("upload:", upload.status, (await upload.json()) as UploadResponse);

for (let tries = 0; tries < 30; tries++) {
  const { characters } = (await (await fetch(`${server}/v1/check`, { headers: auth })).json()) as CheckResponse;
  const mine = characters.find((c) => c.realm === who.realm && c.name === who.name);
  if (mine?.version) {
    const download = await fetch(`${server}/v1/versions/${mine.version}`, { headers: auth });
    const text = new TextDecoder().decode(zstdDecompressSync(new Uint8Array(await download.arrayBuffer())));
    console.log(`merged as version ${mine.version}; sessions in it: ${text.split('"on"').length - 1}`);
    process.exit(0);
  }
  await Bun.sleep(1000);
}
throw new Error("no merged version after 30 s");
