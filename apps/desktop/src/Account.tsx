import { Button } from "@road-to-sixty/ui/Button";
import { addFolder, unlink, type Status } from "./api";
import { Shell, type Tab } from "./Characters";

export function Account({ status, onTab }: { status: Status; onTab: (t: Tab) => void }) {
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
          <Button className="self-start" onClick={addFolder}>
            Add a game folder…
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
