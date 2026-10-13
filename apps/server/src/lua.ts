import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { config } from "./config";

export type Limits = { mb: number; seconds: number };
export const LIMITS: Limits = { mb: 512, seconds: 60 };

export type MergeResult =
  | {
      ok: true;
      from: number | null; // the layout the upload was saved in
      layout: number;
      level: number | null;
      played: number | null;
      lastSeen: number | null; // Unix seconds of the last event
      journey: Uint8Array; // Parse.Write text
    }
  | { ok: false; from: number | null; reason: string };

const num = (s: string | undefined) => (s === undefined || s === "-" ? null : Number(s));

// Runs runner.lua under standard Lua 5.1 as its own process, in a fresh
// folder holding only the upload and the current journey.
export async function runMerge(
  upload: Uint8Array,
  current: Uint8Array | null,
  pc: string,
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
    const args = [uploadPath, current ? currentPath : "", outPath, pc, String(limits.mb), String(limits.seconds)];
    const proc = Bun.spawn([config.lua51, runner, config.luaDir, ...args], {
      stdout: "pipe",
      stderr: "pipe",
      // The runner stops itself at the limit; this is for when it can't.
      timeout: limits.seconds * 1000 + 2000,
      killSignal: "SIGKILL",
    });
    const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    await proc.exited;
    // Bun sets proc.killed after any exit; a signal means it was stopped.
    if (proc.signalCode) return { ok: false, from: null, reason: "the merge didn't finish in time and was stopped" };
    const [word, from, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word === "ok") {
      const [layout, level, played, lastSeen] = rest;
      return {
        ok: true,
        from: num(from),
        layout: Number(layout),
        level: num(level),
        played: num(played),
        lastSeen: num(lastSeen),
        journey: new Uint8Array(await Bun.file(outPath).arrayBuffer()),
      };
    }
    if (word === "rejected") return { ok: false, from: num(from), reason: rest.join(" ") };
    const first = (stderr || stdout).trim().split("\n")[0];
    return { ok: false, from: null, reason: `the merge failed: ${first || `exit code ${proc.exitCode}`}` };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
