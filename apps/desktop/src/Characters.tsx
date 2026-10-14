import type { CharacterInfo } from "@road-to-sixty/api";
import compass from "@road-to-sixty/ui/compass.png";
import { Button } from "@road-to-sixty/ui/Button";
import type { ReactNode } from "react";
import { characters, setPaused, useLoad, type Status } from "./api";
import { CLASS_ICONS } from "./classes";
import { CLASSES, characterLine, levelClass, played } from "./format";

export type Tab = "characters" | "account";

export function Characters({ status, onTab, onOpen }: { status: Status; onTab: (t: Tab) => void; onOpen: (c: CharacterInfo) => void }) {
  const server = useLoad(characters, [status.lastSynced]);
  const now = new Date();
  const info = new Map((server.data ?? []).map((c) => [`${c.name}-${c.realm}`, c]));
  return (
    <Shell status={status} tab="characters" onTab={onTab}>
      <ul className="flex flex-1 flex-col gap-2 overflow-y-auto px-4 py-3.5">
        {status.characters.length === 0 && (
          <li className="px-1 text-[13px] text-muted">No characters yet. Log in to a character with the addon, then log out or type /reload.</li>
        )}
        {status.characters.map((c) => {
          const i = info.get(c.key);
          const [name, ...realm] = c.key.split("-");
          const warn = c.updateAddon || c.problem !== null;
          const look = CLASSES[i?.class ?? ""];
          const icon = CLASS_ICONS[i?.class ?? ""];
          const box = `flex w-full items-center gap-2.5 rounded-[10px] border px-3.5 py-3 text-left ${warn ? "border-warn-line bg-[#0f0d0a]" : "border-line bg-panel"}`;
          const body = (
            <>
              {icon ? (
                <img src={icon} alt="" className="size-[34px] shrink-0 self-start rounded-full" />
              ) : (
                <span aria-hidden="true" className="size-[34px] shrink-0 self-start rounded-full border border-dashed border-[#3a3746]" />
              )}
              <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                <div className="flex items-baseline gap-2">
                  <span className="text-[15px] font-medium" style={{ color: look?.colour }}>
                    {name}
                  </span>
                  <span className="truncate text-[13px] text-muted">{(i && levelClass(i)) || realm.join("-")}</span>
                  {i?.played != null && <span className="ml-auto font-mono text-xs text-muted">{played(i.played)}</span>}
                </div>
                <div className={`text-xs leading-[1.45] ${warn ? "text-warn" : "text-faint"}`}>{warn || !i ? c.note : characterLine(i, now)}</div>
              </div>
              {i && (
                <span aria-hidden="true" className="text-base text-faint">
                  ›
                </span>
              )}
            </>
          );
          return (
            <li key={c.key}>
              {i ? (
                <button type="button" className={box} onClick={() => onOpen(i)}>
                  {body}
                </button>
              ) : (
                <div className={box}>{body}</div>
              )}
            </li>
          );
        })}
      </ul>
      {server.error && <p className="mx-5 mb-2 text-xs text-warn">Couldn't load from the server: {server.error}</p>}
      <footer className="flex gap-2 border-t border-line-soft px-4 py-3">
        <Button onClick={() => setPaused(!status.paused)}>{status.paused ? "Resume syncing" : "Pause syncing"}</Button>
      </footer>
    </Shell>
  );
}

// The header, status pill and tabs both main screens share.
export function Shell({ status, tab, onTab, children }: { status: Status; tab: Tab; onTab: (t: Tab) => void; children: ReactNode }) {
  const good =
    !status.paused && !status.offline && status.problems.length === 0 && !status.characters.some((c) => c.problem);
  return (
    <main className="flex h-full flex-col">
      <div className="flex items-center gap-2.5 px-5 py-3.5">
        <img src={compass} alt="" className="size-7 rounded-md" />
        <div className="flex flex-1 flex-col">
          <div className="text-sm font-medium">Road to Sixty</div>
          <div className="text-xs text-muted">{status.linkedTo}</div>
        </div>
        <div className="flex h-[26px] items-center gap-1.5 rounded-full border border-outline px-2.5 text-xs text-[#c9c4d6]">
          <span className={`size-[7px] rounded-full ${good ? "bg-accent" : "bg-warn"}`} />
          {status.line}
        </div>
      </div>
      <nav aria-label="Sections" className="mx-4 flex gap-0.5 rounded-[10px] border border-line bg-panel p-[3px]">
        {(["characters", "account"] as const).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => onTab(t)}
            className={`flex-1 rounded-[7px] py-1.5 text-[13px] capitalize ${t === tab ? "bg-tab text-text" : "text-muted"}`}
          >
            {t}
          </button>
        ))}
      </nav>
      {status.problems.length > 0 && <p className="mx-5 mt-3 text-xs text-warn">{status.problems[0]}</p>}
      {children}
    </main>
  );
}
