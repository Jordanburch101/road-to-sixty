import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { config } from "./config";

export type Limits = { mb: number; seconds: number };
export const LIMITS: Limits = { mb: 512, seconds: 60 };

// A stretch of time a restore took out: [from, to] in Unix seconds.
export type Window = [number, number];

export type MergeResult =
  | {
      ok: true;
      from: number | null; // the layout the upload was saved in
      layout: number;
      level: number | null;
      played: number | null;
      lastSeen: number | null; // Unix seconds of the last event
      class: string | null; // the class file name, such as WARRIOR
      journey: Uint8Array; // Parse.Write text
    }
  // The merge rules refused the upload. Faults (a crash, a limit, a bug)
  // throw instead, so the job is tried again.
  | { ok: false; from: number | null; reason: string };

const num = (s: string | undefined) => (s === undefined || s === "-" ? null : Number(s));

// Runs runner.lua under standard Lua 5.1 as its own process.
async function run(args: string[], limits: Limits, runner: string) {
  const proc = Bun.spawn([config.lua51, runner, config.luaDir, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    // The runner stops itself at the limit; this is for when it can't.
    timeout: limits.seconds * 1000 + 2000,
    killSignal: "SIGKILL",
  });
  const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  await proc.exited;
  // Bun sets proc.killed after any exit; a signal means it was stopped
  // for running too long: the server's fault.
  if (proc.signalCode) throw new Error("the merge didn't finish in time and was stopped");
  return { stdout, stderr, exitCode: proc.exitCode };
}

// Merges in a fresh folder holding only the upload, the current journey
// and the windows to strip from the upload.
export async function runMerge(
  upload: Uint8Array,
  current: Uint8Array | null,
  pc: string,
  windows: Window[] = [],
  limits: Limits = LIMITS,
  runner = `${import.meta.dir}/runner.lua`,
): Promise<MergeResult> {
  const dir = await mkdtemp(join(tmpdir(), "rts-merge-"));
  try {
    const uploadPath = join(dir, "upload.lua");
    const currentPath = join(dir, "current.lua");
    const outPath = join(dir, "out.lua");
    await Bun.write(uploadPath, upload);
    if (current) await Bun.write(currentPath, current);
    const windowsPath = join(dir, "windows.txt");
    if (windows.length > 0) await Bun.write(windowsPath, windows.map(([from, to]) => `${from} ${to}`).join("\n"));
    const args = ["merge", uploadPath, current ? currentPath : "", outPath, pc, windows.length > 0 ? windowsPath : "", String(limits.mb), String(limits.seconds)];
    const { stdout, stderr, exitCode } = await run(args, limits, runner);
    const [word, from, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word === "ok") {
      const [layout, level, played, lastSeen, cls] = rest;
      return {
        ok: true,
        from: num(from),
        layout: Number(layout),
        level: num(level),
        played: num(played),
        lastSeen: num(lastSeen),
        class: cls === undefined || cls === "-" ? null : cls,
        journey: new Uint8Array(await Bun.file(outPath).arrayBuffer()),
      };
    }
    if (word === "rejected") return { ok: false, from: num(from), reason: rest.join(" ") };
    // "failed", or no result at all: the server's fault, tried again later.
    const why = word === "failed" ? [from, ...rest].join(" ") : (stderr || stdout).trim().split("\n")[0];
    throw new Error(`the merge failed: ${why || `exit code ${exitCode}`}`);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// The sessions a restore from old to kept takes out (Merge.Windows), both
// stored journeys. Run under the same limits as a merge.
export async function runWindows(old: Uint8Array, kept: Uint8Array, limits: Limits = LIMITS, runner = `${import.meta.dir}/runner.lua`): Promise<Window[]> {
  const dir = await mkdtemp(join(tmpdir(), "rts-windows-"));
  try {
    await Bun.write(join(dir, "old.lua"), old);
    await Bun.write(join(dir, "kept.lua"), kept);
    const { stdout, stderr, exitCode } = await run(["windows", join(dir, "old.lua"), join(dir, "kept.lua"), String(limits.mb), String(limits.seconds)], limits, runner);
    const [word, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word !== "windows") throw new Error(`the restore's sessions couldn't be worked out: ${(word === "failed" ? rest.join(" ") : stderr.trim().split("\n")[0]) || `exit code ${exitCode}`}`);
    const n = rest.filter((s) => s !== "").map(Number);
    const out: Window[] = [];
    for (let i = 0; i + 1 < n.length; i += 2) out.push([n[i]!, n[i + 1]!]);
    return out;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
