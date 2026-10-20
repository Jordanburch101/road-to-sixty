import compass from "@road-to-sixty/ui/compass.png";
import { Button } from "@road-to-sixty/ui/Button";
import { Fog } from "@road-to-sixty/ui/Fog";
import type { Point } from "@road-to-sixty/ui/dots";
import { memo, type ReactNode, type RefObject } from "react";
import type { Demo, Step as StepState, Target } from "../demo";
import { Fold, Swap } from "./DemoMotion";

// The app's first run screen (apps/desktop/src/FirstRun.tsx), copied by hand
// for the demo: keep the two in step when the app's screen changes. The app's
// window is always 400 wide; below 380 px the text wraps more, so the spacing
// tightens there to keep every step inside the 640 px window.

const ROAD: Point[] = [[150, 190], [205, 150], [240, 118], [290, 104], [330, 70], [372, 52], [420, 20]];
const ROADS = [ROAD];
const MARKS: Point[] = [[240, 118], [330, 70]];

export type Buttons = Record<Exclude<Target, "icon">, RefObject<HTMLDivElement | null>>;

const cream = (pressed: boolean) =>
  `h-10 w-full rounded-[10px] text-sm transition-[scale,filter] duration-100 ${pressed ? "scale-[0.97] brightness-90" : ""}`;

export function DemoSetup({ demo, still, shown, pressed, buttons }: { demo: Demo; still: boolean; shown: boolean; pressed: Target | null; buttons: Buttons }) {
  const [one, two, three] = demo.steps;
  return (
    <main
      className={`absolute inset-0 flex flex-col transition-[opacity,translate] duration-500 ease-[cubic-bezier(0.16,1,0.3,1)] ${shown ? "" : "-translate-x-6 opacity-0"}`}
    >
      <Header />
      <ol className="flex min-h-0 flex-1 flex-col gap-[18px] overflow-hidden px-6 py-5 max-[379px]:gap-3 max-[379px]:px-5 max-[379px]:py-4">
        <Step n={1} state={one} still={still} title={demo.installed ? "Addon installed" : "Install the addon"}>
          <div className="mt-2.5 flex min-w-0 flex-col gap-0.5 rounded-[10px] border border-line bg-panel px-3 py-2.5">
            <div className="flex items-baseline gap-2">
              <span className="text-sm font-medium">Classic</span>
              <Swap className="ml-auto whitespace-nowrap text-right text-xs text-muted" text={demo.installed ? "Addon 1.10.2" : "No addon yet"} />
            </div>
            <div className="truncate text-[11.5px] text-faint">/Applications/World of Warcraft</div>
          </div>
          <Fold open={!demo.installed}>
            <div className="flex flex-col gap-2.5 pt-2.5">
              <div ref={buttons.install} className="flex">
                <Button look="cream" tabIndex={-1} className={cream(pressed === "install")}>
                  Install Road to Sixty 1.10.2
                </Button>
              </div>
              <p className="text-xs text-faint">Puts the addon in this game's AddOns folder. It keeps itself up to date after that.</p>
            </div>
          </Fold>
        </Step>

        <Step n={2} state={two} still={still} title="Link this PC">
          <p className="mt-2.5 text-[13px] leading-snug text-muted">
            Give this PC a name you'll recognise, sign in with Battle.net in your browser, check the code matches, and click Link.
          </p>
          <Fold open={two === "current"}>
            <div className="flex flex-col gap-2.5 pt-2.5">
              <div className="flex flex-col gap-1.5 text-xs text-muted">
                This PC's name
                <div
                  className={`flex h-9 items-center rounded-lg border bg-ground px-2.5 text-sm text-text transition-colors duration-300 ${two === "current" ? "border-accent" : "border-outline"}`}
                >
                  {[...demo.typed].map((c, i) => (
                    <span key={i} className={`whitespace-pre ${still ? "" : "demo-type"}`}>
                      {c}
                    </span>
                  ))}
                  <span className={`ml-px h-4 w-px bg-text ${two === "current" && !still ? "demo-caret" : "opacity-0"}`} />
                </div>
              </div>
              <div ref={buttons.link} className="flex">
                <Button look="cream" tabIndex={-1} className={cream(pressed === "link")}>
                  Link this PC
                </Button>
              </div>
            </div>
          </Fold>
          <Fold open={demo.linked}>
            <p className="pt-2.5 text-[13px] text-muted">Linked to Player#0000.</p>
          </Fold>
        </Step>

        <Step n={3} state={three} still={still} title="Restart WoW once">
          <p className="mt-2.5 text-[13px] leading-snug text-muted">So the game loads the addon and the sync folder. Your journeys stay where they are.</p>
          <Fold open={three === "current"}>
            <div className="pt-2.5">
              <div ref={buttons.done} className="flex">
                <Button look="cream" tabIndex={-1} className={cream(pressed === "done")}>
                  Done
                </Button>
              </div>
            </div>
          </Fold>
        </Step>
      </ol>

      <footer className="flex shrink-0 items-center justify-between border-t border-line-soft px-6 py-3.5 text-[13px] max-[379px]:px-5 max-[379px]:py-3">
        <span className="text-[#c9c4d6]">Add a game folder…</span>
        <span className="text-faint">Free · works offline</span>
      </footer>
    </main>
  );
}

// The fog is the heaviest part of the screen and never changes.
const Header = memo(function Header() {
  return (
    <header className="relative shrink-0 overflow-hidden border-b border-line-soft px-6 pb-5 pt-6 max-[379px]:px-5 max-[379px]:pb-4 max-[379px]:pt-4">
      <div className="pointer-events-none absolute inset-0 [mask-image:linear-gradient(to_right,transparent_30%,#000_75%)]">
        <Fog width={400} height={180} step={14} roads={ROADS} marks={MARKS} />
      </div>
      <img src={compass.src} alt="" width={48} height={48} className="relative size-12 rounded-[10px] max-[379px]:size-10" />
      <h1 className="relative mt-3.5 text-xl max-[379px]:mt-2.5 font-medium tracking-tight">Set up Road to Sixty</h1>
      <p className="relative mt-1 text-sm text-muted">Three steps, once. After that it runs by itself.</p>
    </header>
  );
});

function Step({ n, state, still, title, children }: { n: number; state: StepState; still: boolean; title: string; children: ReactNode }) {
  const done = state === "done";
  const current = state === "current";
  const dot = done ? "border-accent-soft bg-accent-soft text-accent" : current ? "border-text text-text" : "border-outline text-faint";
  return (
    <li className="flex gap-3">
      <div className={`flex size-[22px] shrink-0 items-center justify-center rounded-full border text-xs transition-colors duration-300 ${dot}`}>
        <span key={done ? "tick" : "number"} className={`inline-block ${still ? "" : done ? "demo-pop" : "demo-in"}`}>
          {done ? "✓" : n}
        </span>
      </div>
      <div className="flex min-w-0 flex-1 flex-col">
        <div className={`text-sm font-medium transition-colors duration-300 ${done || current ? "text-text" : "text-muted"}`}>
          <Swap className="block" text={title} />
        </div>
        {children}
      </div>
    </li>
  );
}
