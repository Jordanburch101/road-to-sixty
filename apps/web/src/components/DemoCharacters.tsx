import compass from "@road-to-sixty/ui/compass.png";
import { Button } from "@road-to-sixty/ui/Button";
import { CLASSES } from "@road-to-sixty/ui/classColours";
import hunter from "@road-to-sixty/ui/classes/hunter.png";
import mage from "@road-to-sixty/ui/classes/mage.png";
import paladin from "@road-to-sixty/ui/classes/paladin.png";
import warrior from "@road-to-sixty/ui/classes/warrior.png";
import { useState } from "react";
import type { Demo, Row as RowData } from "../demo";
import { Roll, Swap } from "./DemoMotion";

// The app's Characters screen and its Shell header (apps/desktop/src/Characters.tsx),
// copied by hand for the demo: keep the two in step when the app's screen changes.

const ICONS: Record<RowData["cls"], string> = { WARRIOR: warrior.src, HUNTER: hunter.src, PALADIN: paladin.src, MAGE: mage.src };

export function DemoCharacters({ demo, still, shown }: { demo: Demo; still: boolean; shown: boolean }) {
  const line = still ? "Synced 2 min ago" : demo.syncing ? "Syncing…" : "Synced just now";
  return (
    <div
      className={`absolute inset-0 flex flex-col transition-[opacity,translate] duration-500 ease-[cubic-bezier(0.16,1,0.3,1)] ${shown ? "" : "translate-x-6 opacity-0"}`}
    >
      <div className="flex items-center gap-2.5 px-5 py-3.5">
        <img src={compass.src} alt="" width={28} height={28} className="size-7 rounded-md" />
        <div className="flex flex-1 flex-col">
          <div className="text-sm font-medium">Road to Sixty</div>
          <div className="text-xs text-muted">Player#0000</div>
        </div>
        <div className="flex h-[26px] items-center gap-1.5 rounded-full border border-outline px-2.5 text-xs text-[#c9c4d6]">
          <span className="relative size-[7px] shrink-0">
            <span className={`absolute inset-0 rounded-full bg-accent transition-opacity duration-300 ${demo.syncing ? "opacity-0" : ""}`} />
            <span
              className={`absolute -inset-px rounded-full border-[1.5px] border-accent border-t-transparent transition-opacity duration-300 demo-spin ${demo.syncing ? "" : "opacity-0"}`}
            />
            {/* Keyed by the count, so the pulse plays once each time it goes up; going back to 0 at the loop's end plays nothing. */}
            <span key={demo.pulse} className={`absolute inset-0 rounded-full bg-accent ${demo.pulse ? "demo-pulse" : "opacity-0"}`} />
          </span>
          <Swap fit className="block overflow-hidden whitespace-nowrap transition-[width] duration-300 ease-out" text={line} />
        </div>
      </div>
      <div className="mx-4 flex gap-0.5 rounded-[10px] border border-line bg-panel p-[3px] text-[13px]">
        <span className="flex-1 rounded-[7px] bg-tab py-1.5 text-center text-text">Characters</span>
        <span className="flex-1 py-1.5 text-center text-muted">Account</span>
      </div>
      <ul className="flex min-h-0 flex-1 flex-col overflow-hidden px-4 py-3.5">
        {demo.rows.map((r) => (
          <Row key={r.name} row={r} arrive={!still} />
        ))}
      </ul>
      <div className="flex shrink-0 gap-2 border-t border-line-soft px-4 py-3">
        <Button tabIndex={-1}>Pause syncing</Button>
      </div>
    </div>
  );
}

function Row({ row, arrive }: { row: RowData; arrive: boolean }) {
  // Fixed when the row first shows, so the still picture's rows never rise.
  const [rise] = useState(arrive);
  const c = CLASSES[row.cls]!;
  return (
    <li className={`grid grid-rows-[1fr] ${rise ? "demo-arrive" : ""}`}>
      {/* The extra room around the row, taken back by the negative margins, keeps its glow from being clipped. */}
      <div className="-mx-2 -mt-2 min-h-0 overflow-hidden px-2 pt-2">
        <div
          className={`flex w-full items-center gap-2.5 rounded-[10px] border bg-panel px-3.5 py-3 max-[359px]:gap-2 max-[359px]:px-2.5 max-[359px]:py-2.5 transition-[border-color,box-shadow] ${
            row.glow
              ? "border-accent/70 shadow-[0_0_0_1px_rgba(58,160,255,0.3),0_0_10px_rgba(58,160,255,0.3)] duration-300"
              : "border-line duration-[1200ms]"
          }`}
        >
          <img src={ICONS[row.cls]} alt="" width={34} height={34} className="size-[34px] shrink-0 self-start rounded-full" />
          <div className="flex min-w-0 flex-1 flex-col gap-1.5">
            <div className="flex items-baseline gap-x-2 max-[379px]:flex-wrap">
              <span className="text-[15px] font-medium" style={{ color: c.colour }}>
                {row.name}
              </span>
              <span className="whitespace-nowrap text-[13px] text-muted max-[379px]:order-last max-[379px]:basis-full">
                Level <Roll text={String(row.level)} /> {c.name}
              </span>
              <span className="ml-auto font-mono text-xs text-muted">
                <Roll text={row.played} />
              </span>
            </div>
            <Swap className="block text-xs leading-[1.45] text-faint" text={row.line} />
          </div>
          <span className="text-base text-faint">›</span>
        </div>
        {/* A spacer rather than the app's gap-2, so the gap folds open with the arriving row. */}
        <div className="h-2" />
      </div>
    </li>
  );
}
