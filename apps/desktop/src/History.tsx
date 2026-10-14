import type { CharacterInfo } from "@road-to-sixty/api";
import { Button } from "@road-to-sixty/ui/Button";
import { useState } from "react";
import { restore, useLoad, versions, type Status } from "./api";
import { CLASS_ICONS } from "@road-to-sixty/ui/classes";
import { CLASSES, levelClass, played, versionLine, when } from "./format";

// A character's merged and restored versions, newest first, after the
// A-History mockup. Restoring asks first, in the row itself.
export function History({ status, character, onBack }: { status: Status; character: CharacterInfo; onBack: () => void }) {
  const list = useLoad(() => versions(character.id), [character.id, status.lastSynced]);
  const [asking, setAsking] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const now = new Date();
  const icon = CLASS_ICONS[character.class ?? ""];

  async function pick(version: number) {
    setError(null);
    try {
      await restore(character.id, version);
      setAsking(null);
      list.reload();
    } catch (e) {
      setError(`Couldn't restore: ${String(e)}`);
    }
  }

  return (
    <main className="flex h-full flex-col">
      <div className="flex flex-col gap-3 px-5 pb-1 pt-3.5">
        <button type="button" onClick={onBack} className="self-start text-[13px] text-[#c9c4d6] hover:text-text">
          ‹ Characters
        </button>
        <div className="flex items-center gap-3">
          {icon && <img src={icon} alt="" className="size-11 rounded-full" />}
          <div className="flex flex-col gap-1">
            <div className="flex items-baseline gap-2">
              <h1 className="text-xl font-medium tracking-tight" style={{ color: CLASSES[character.class ?? ""]?.colour }}>
                {character.name}
              </h1>
              <span className="text-[13px] text-muted">{levelClass(character)}</span>
            </div>
            <div className="text-xs text-faint">
              {[character.realm, character.played !== null ? `${played(character.played)} played` : ""].filter(Boolean).join(" · ")}
            </div>
          </div>
        </div>
      </div>
      <h2 className="mx-5 mt-3.5 text-xs font-medium text-faint">History</h2>
      {(error || list.error) && <p className="mx-5 mt-2 text-xs text-warn">{error ?? `Couldn't load the history: ${list.error}`}</p>}
      <ol className="flex flex-1 flex-col gap-2 overflow-y-auto [scrollbar-gutter:stable] px-4 pb-4 pt-2">
        {list.data?.map((v) =>
          v.current ? (
            <li key={v.id} className="flex flex-col gap-1 rounded-[10px] border border-outline bg-panel px-3.5 py-3">
              <div className="flex items-baseline gap-2">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="ml-auto flex h-5 items-center rounded-full bg-accent-soft px-2 text-[11px] text-accent">Current</span>
              </div>
              <div className="text-xs text-muted">{versionLine(v, now)}</div>
            </li>
          ) : asking === v.id ? (
            <li key={v.id} className="flex flex-col gap-2.5 rounded-[10px] border border-[#3a3746] bg-[#100f15] px-3.5 py-3">
              <div className="flex flex-col gap-1">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="text-xs text-muted">{versionLine(v, now)}</span>
              </div>
              <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">
                Go back to this version? {character.name}'s journey on each PC changes at its next login. The current version stays in this list, so you can
                switch back.
              </p>
              <div className="flex gap-2">
                <Button look="cream" onClick={() => pick(v.id)}>
                  Restore this version
                </Button>
                <Button onClick={() => setAsking(null)}>Cancel</Button>
              </div>
            </li>
          ) : (
            <li key={v.id} className="flex items-center gap-2.5 rounded-[10px] border border-line bg-panel px-3.5 py-3">
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">{when(v.createdAt, now)}</span>
                <span className="text-xs text-muted">{versionLine(v, now)}</span>
              </div>
              <Button className="h-[30px] rounded-lg px-3 text-xs" onClick={() => setAsking(v.id)}>
                Restore
              </Button>
            </li>
          ),
        )}
      </ol>
    </main>
  );
}
