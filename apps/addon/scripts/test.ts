// Runs every offline test (tests/*_test.lua) under LuaJIT, then again under
// standard Lua 5.1 when it is installed: lua5.1 on the path, or the
// interpreter LUA51 names. The sync server runs the shared files under
// Lua 5.1, so CI installs both. Run from apps/addon: bun scripts/test.ts

const root = `${import.meta.dir}/..`;
const tests = [...new Bun.Glob("tests/*_test.lua").scanSync({ cwd: root })].sort();
const lua51 = process.env.LUA51 ?? Bun.which("lua5.1");
const runtimes = ["luajit", ...(lua51 ? [lua51] : [])];

let failed = 0;
for (const lua of runtimes) {
  for (const test of tests) {
    const run = Bun.spawnSync([lua, test], { cwd: root, stdout: "pipe", stderr: "pipe" });
    if (run.exitCode !== 0) {
      failed++;
      console.log(`FAILED under ${lua}: ${test}\n${run.stdout}${run.stderr}`);
    }
  }
  console.log(`${lua}: ${tests.length} test files`);
}
if (!lua51) console.log("lua5.1 not found: the standard Lua 5.1 run was skipped");
process.exit(failed > 0 ? 1 : 0);
