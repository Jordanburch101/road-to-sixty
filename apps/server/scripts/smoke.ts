// Checks a built image can merge: Lua 5.1, the runner and the addon's files
// are all where the server looks. CI runs it inside the image.
import { runMerge } from "../src/lua";

const upload = new TextEncoder().encode('RoadToSixtyCharDB = {["version"] = 3, ["events"] = {{100, "on"}}}');
const result = await runMerge(upload, null, "smoke");
console.log(result.ok ? `merge ok, layout ${result.layout}` : `merge failed: ${result.reason}`);
process.exit(result.ok ? 0 : 1);
