import compass from "@road-to-sixty/ui/compass.png";
import { Button } from "@road-to-sixty/ui/Button";
import { Fog } from "@road-to-sixty/ui/Fog";
import type { Point } from "@road-to-sixty/ui/dots";
import { useEffect, useState, type ReactNode } from "react";
import { hostName, link, pickFolder, setStartsAtLogin, type Status } from "./api";

const ROAD: Point[] = [[150, 190], [205, 150], [240, 118], [290, 104], [330, 70], [372, 52], [420, 20]];
const MARKS: Point[] = [[240, 118], [330, 70]];

export function FirstRun({ status, onDone }: { status: Status; onDone: () => void }) {
  const [name, setName] = useState("");
  useEffect(() => void hostName().then((n) => setName((typed) => typed || n)), []);
  const found = status.games.length > 0;
  const linked = status.linkedTo !== null;
  return (
    <main className="flex h-full flex-col">
      <header className="relative overflow-hidden border-b border-line-soft px-6 pb-5 pt-6">
        <div className="pointer-events-none absolute inset-0 [mask-image:linear-gradient(to_right,transparent_30%,#000_75%)]">
          <Fog width={400} height={180} step={14} roads={[ROAD]} marks={MARKS} />
        </div>
        <img src={compass} alt="" className="relative size-12 rounded-[10px]" />
        <h1 className="relative mt-3.5 text-xl font-medium tracking-tight">Set up Road to Sixty</h1>
        <p className="relative mt-1 text-sm text-muted">Three steps, once. After that it runs by itself.</p>
      </header>

      <ol className="flex flex-1 flex-col gap-[18px] px-6 py-5">
        <Step n={1} done={found} title={found ? "WoW found" : "WoW not found"}>
          {status.games.map((g) => (
            <div key={g.path} className="min-w-0">
              <div className="truncate font-mono text-xs text-muted">{g.path}</div>
              <div className="text-[13px] text-muted">{g.name} · Road to Sixty {g.addon ?? "(developer copy)"}</div>
            </div>
          ))}
          {!found && <p className="text-[13px] text-muted">Install the Road to Sixty addon first, or show us where WoW is.</p>}
        </Step>

        <Step n={2} done={linked} current={found && !linked} title="Link this PC">
          <p className="text-[13px] leading-snug text-muted">Give this PC a name you'll recognise, sign in with Battle.net in your browser, check the code matches, and click Link.</p>
          {found && !linked && (
            <>
              {!status.linkCode && (
                <label className="flex flex-col gap-1.5 text-xs text-muted">
                  This PC's name
                  <input
                    value={name}
                    maxLength={40}
                    autoComplete="off"
                    onChange={(e) => setName(e.target.value)}
                    className="h-9 rounded-lg border border-outline bg-ground px-2.5 text-sm text-text outline-none focus:border-accent"
                  />
                </label>
              )}
              <Button look={status.linkCode ? "outline" : "cream"} className="h-10 w-full rounded-[10px] text-sm" onClick={() => link(name)}>
                {status.linkCode ? "Start over" : "Link this PC"}
              </Button>
              {status.linkCode && (
                <div className="text-xs text-muted">
                  Waiting for your browser. Your code: <span className="font-mono tracking-[0.08em] text-text">{status.linkCode}</span>
                  {status.linkUrl && (
                    <span className="mt-1 block select-text">
                      No browser? Open <span className="break-all text-text">{status.linkUrl}</span>
                    </span>
                  )}
                </div>
              )}
            </>
          )}
          {linked && <p className="text-[13px] text-muted">Linked to {status.linkedTo}.</p>}
        </Step>

        <Step n={3} current={linked} title="Restart WoW once">
          <p className="text-[13px] leading-snug text-muted">So the game loads the sync folder. Your journeys stay where they are.</p>
          {linked && (
            <Button look="cream" className="h-10 w-full rounded-[10px] text-sm" onClick={() => setStartsAtLogin(true).catch(() => {}).then(onDone)}>
              Done
            </Button>
          )}
        </Step>
      </ol>

      {status.problems.length > 0 && <p className="px-6 pb-3 text-xs text-warn">{status.problems[0]}</p>}
      <footer className="flex items-center justify-between border-t border-line-soft px-6 py-3.5 text-[13px]">
        <button type="button" className="text-[#c9c4d6] hover:text-text" onClick={pickFolder}>
          Add a game folder…
        </button>
        <span className="text-faint">Free · works offline</span>
      </footer>
    </main>
  );
}

function Step({ n, title, done = false, current = false, children }: { n: number; title: string; done?: boolean; current?: boolean; children: ReactNode }) {
  const dot = done ? "bg-accent-soft text-accent" : current ? "border border-text text-text" : "border border-outline text-faint";
  return (
    <li className="flex gap-3">
      <div className={`flex size-[22px] shrink-0 items-center justify-center rounded-full text-xs ${dot}`}>{done ? "✓" : n}</div>
      <div className="flex min-w-0 flex-1 flex-col gap-2.5">
        <div className={`text-sm font-medium ${done || current ? "" : "text-muted"}`}>{title}</div>
        {children}
      </div>
    </li>
  );
}
