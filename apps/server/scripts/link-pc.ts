// Links this machine as a PC the way the desktop app will, to try sign-in
// against a running server. Prints the PC token once, and the PC's ID.
//   bun scripts/link-pc.ts <server URL> [PC name]
import { APP_CLIENT_ID, type LinkResponse } from "@road-to-sixty/api";

const [server, name = "Script"] = process.argv.slice(2);
if (!server) throw new Error("usage: bun scripts/link-pc.ts <server URL> [PC name]");

// Better Auth's device sign-in answers (RFC 8628).
type Answer = Record<string, string> & { interval: number };
const post = async (path: string, body: object) =>
  (await (await fetch(`${server}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })).json()) as Answer;

const code = await post("/api/auth/device/code", { client_id: APP_CLIENT_ID });
console.log(`Open ${code.verification_uri_complete} and link code ${code.user_code}.`);
for (;;) {
  await Bun.sleep(code.interval * 1000);
  const answer = await post("/api/auth/device/token", {
    grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    device_code: code.device_code,
    client_id: APP_CLIENT_ID,
  });
  if (answer.access_token) {
    const query = new URLSearchParams({ name, platform: process.platform });
    const linked = await fetch(`${server}/v1/link?${query}`, { method: "POST", headers: { authorization: `Bearer ${answer.access_token}` } });
    const { token, pc } = (await linked.json()) as LinkResponse;
    console.log(`Linked as PC ${pc}. Its token, shown only now:\n${token}`);
    break;
  }
  if (answer.error !== "authorization_pending" && answer.error !== "slow_down") throw new Error(answer.error_description ?? answer.error);
}
