import { Button } from "@road-to-sixty/ui/Button";
import { useEffect, useState } from "react";
import { pickFolder, checkUpdate, installUpdate, setStartsAtLogin, startsAtLogin, unlink, type Status } from "./api";
import { Shell, type Tab } from "./Characters";

export function Account({ status, onTab }: { status: Status; onTab: (t: Tab) => void }) {
  const [atLogin, setAtLogin] = useState(false);
  // undefined: not checked yet; null: up to date; a string: the version on offer.
  const [update, setUpdate] = useState<string | null | undefined>(undefined);
  useEffect(() => void startsAtLogin().then(setAtLogin), []);
  return (
    <Shell status={status} tab="account" onTab={onTab}>
      <div className="flex flex-1 flex-col gap-5 overflow-y-auto px-5 py-4 text-[13px]">
        <section className="flex flex-col gap-2">
          <h2 className="text-xs font-medium text-faint">Game folders</h2>
          {status.games.map((g) => (
            <div key={g.path} className="rounded-[10px] border border-line bg-panel px-3.5 py-2.5">
              <div className="truncate font-mono text-xs text-muted">{g.path}</div>
              <div className="text-xs text-faint">
                {g.name} · Road to Sixty {g.addon ?? "(developer copy)"}
              </div>
            </div>
          ))}
          <Button className="self-start" onClick={pickFolder}>
            Add a game folder…
          </Button>
        </section>
        <section className="flex flex-col gap-2">
          <h2 className="text-xs font-medium text-faint">Start at login</h2>
          <label className="flex items-center gap-2 text-muted">
            <input type="checkbox" checked={atLogin} onChange={(e) => setStartsAtLogin(e.target.checked).then(() => setAtLogin(e.target.checked))} />
            Start Road to Sixty when you log in, so every session is backed up
          </label>
        </section>
        <section className="flex flex-col gap-2">
          <h2 className="text-xs font-medium text-faint">Updates</h2>
          <p className="text-muted">{update === undefined ? "Checks by itself every few hours." : update ? `Version ${update} is ready.` : "You have the newest version."}</p>
          <Button className="self-start" onClick={() => (update ? installUpdate() : checkUpdate().then(setUpdate))}>
            {update ? "Restart to update" : "Check now"}
          </Button>
        </section>
        <section className="flex flex-col gap-2">
          <h2 className="text-xs font-medium text-faint">This PC</h2>
          <p className="text-muted">Linked to {status.linkedTo}. Unlinking stops syncing here; your journeys stay on this PC and on the server.</p>
          <Button className="self-start" onClick={unlink}>
            Unlink this PC
          </Button>
        </section>
      </div>
    </Shell>
  );
}
