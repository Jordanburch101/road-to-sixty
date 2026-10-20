import compass from "@road-to-sixty/ui/compass.png";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import gauntlet from "../assets/demo/cursor-gauntlet.png";
import { advance, demoAt, LINES, LOOP, STILL, STILL_LINES, type Demo, type Line } from "../demo";
import { DemoCharacters } from "./DemoCharacters";
import { DemoSetup } from "./DemoSetup";
import { Roll, Swap, useChange } from "./DemoMotion";

// The home page's app demo (docs/superpowers/specs/2026-10-20-app-demo-design.md):
// the still picture in the page's HTML, then, once half of it (or half the
// screen, on short screens) is in view, the story from demo.ts on a loop.
// Every change moves through CSS; this only keeps time.

const STORY = "The Road to Sixty app, shown as a short looping demo of setting it up and syncing characters.";

// The loop starts a second early, while the still picture's rows close with the window.
const CLOSING: Demo = { ...STILL, open: false };

const view = (t: number, phone: boolean) => (t < 0 ? CLOSING : demoAt(t, phone));

export function AppDemo() {
  // t is null until the loop starts.
  const [{ t, demo }, setNow] = useState<{ t: number | null; demo: Demo }>({ t: null, demo: STILL });
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const reduce = matchMedia("(prefers-reduced-motion: reduce)");
    const narrow = matchMedia("(max-width: 767px)");
    let time = 0;
    let started = false;
    let seen = false;
    let frame = 0;
    let last = 0;
    let shown = "";

    // React hears about a frame only when what it shows changes.
    const show = () => {
      const d = view(time, narrow.matches);
      const now = JSON.stringify(d);
      if (now === shown) return;
      shown = now;
      setNow({ t: time, demo: d });
    };
    const tick = (now: number) => {
      time = advance(time, last ? now - last : 0);
      last = now;
      if (time >= LOOP) time -= LOOP;
      show();
      frame = requestAnimationFrame(tick);
    };
    const run = () => {
      const go = seen && !document.hidden && !reduce.matches;
      if (go && !frame) {
        if (!started) {
          started = true;
          time = -1;
        }
        last = 0;
        frame = requestAnimationFrame(tick);
      } else if (!go && frame) {
        cancelAnimationFrame(frame);
        frame = 0;
      }
    };
    const onReduce = () => {
      if (reduce.matches) {
        started = false;
        shown = "";
        setNow({ t: null, demo: STILL });
      }
      run();
    };
    // A screen shorter than half the demo could never show half of it, so
    // half the screen's height counts as seen too.
    const seeing = new IntersectionObserver(
      (entries) => {
        const e = entries[entries.length - 1]!;
        seen = e.isIntersecting && e.intersectionRect.height >= Math.min(e.boundingClientRect.height, e.rootBounds?.height ?? innerHeight) / 2;
        run();
      },
      { threshold: [0, 0.25, 0.5, 0.75, 1] },
    );

    seeing.observe(root.current!);
    reduce.addEventListener("change", onReduce);
    document.addEventListener("visibilitychange", run);
    return () => {
      seeing.disconnect();
      reduce.removeEventListener("change", onReduce);
      document.removeEventListener("visibilitychange", run);
      cancelAnimationFrame(frame);
    };
  }, []);

  const still = t === null || t < 0;
  const lines = still ? STILL_LINES : LINES[demo.part];
  const pressed = demo.cursor.down ? demo.cursor.at : null;

  const win = useRef<HTMLDivElement>(null);
  const [spot, setSpot] = useState<{ x: number; y: number } | null>(null);
  const { at, shown } = demo.cursor;
  useLayoutEffect(() => {
    const move = (x: number, y: number) => setSpot((s) => (s && s.x === x && s.y === y ? s : { x, y }));
    const place = () => {
      const r = root.current!.getBoundingClientRect();
      const b = root.current!.querySelector(`[data-target="${at}"]`)?.getBoundingClientRect();
      // A target with no width is hidden (the menu bar icon on narrow screens), and would pull the cursor to a corner.
      if (shown && b?.width) {
        move(b.left + b.width / 2 - r.left, b.top + b.height / 2 - r.top);
      } else if (!shown && at === "icon") {
        // Parked over the window's lower right while hidden, so it glides in to its first target.
        const w = win.current!.getBoundingClientRect();
        move(w.right - r.left - 70, w.top - r.top + 380);
      }
    };
    place();
    addEventListener("resize", place);
    return () => removeEventListener("resize", place);
  }, [at, shown]);

  return (
    <div ref={root} className="demo relative grid w-full grid-cols-1 items-start gap-8 md:grid-cols-[1fr_400px_1fr] md:gap-12">
      <Lines side="left" now={lines.left} className="order-2 md:order-1 md:pt-[150px] md:text-right" />

      <div role="img" aria-label={STORY} className="pointer-events-none order-1 flex select-none flex-col items-center md:order-2">
        <div
          aria-hidden="true"
          className="hidden h-7 w-[560px] items-center justify-end gap-4 rounded-t-lg border border-b-0 border-[#24212c] bg-[rgba(28,26,35,0.9)] px-3.5 text-xs text-[#c9c4d6] md:flex"
        >
          <span className="h-2.5 w-3.5 rounded-sm border border-faint" />
          <span
            data-target="icon"
            className={`flex size-[22px] items-center justify-center rounded-[5px] transition-[background-color,scale,filter] duration-200 ${demo.open ? "bg-accent/20" : ""} ${pressed === "icon" ? "scale-90 brightness-90" : ""}`}
          >
            <img src={compass.src} alt="" width={15} height={15} className="size-[15px] rounded-[3px]" />
          </span>
          <span className="size-3 rounded-full border border-faint" />
          <Clock text={demo.clock} roll={demo.open} />
        </div>
        <div
          ref={win}
          aria-hidden="true"
          className={`relative h-[640px] w-full max-w-[400px] overflow-hidden rounded-xl border border-[#24212c] bg-ground text-left shadow-[0_30px_90px_rgba(0,0,0,0.6),0_-10px_60px_rgba(58,160,255,0.08)] transition-[opacity,scale] duration-[350ms] ease-out md:ml-[38px] md:mt-2 md:w-[400px] md:origin-[332px_-22px] ${demo.open ? "" : "opacity-0 md:scale-[0.96]"}`}
        >
          <DemoSetup demo={demo} shown={demo.screen === "setup"} pressed={pressed} />
          <DemoCharacters demo={demo} still={still} shown={demo.screen === "characters"} />
        </div>
      </div>

      <Lines side="right" now={lines.right} className="order-3 md:pt-[330px] md:text-left" />

      <ul className="sr-only">
        {Object.values(LINES).flatMap((pair) =>
          [pair.left, pair.right].map((l) => (
            <li key={l.head}>
              {l.head}. {l.text}
            </li>
          )),
        )}
      </ul>

      <Cursor spot={spot} shown={shown} down={demo.cursor.down} />
    </div>
  );
}

const VERSIONS = [STILL_LINES, ...Object.values(LINES)];

// Every version sits in the same grid cell, so the slot is always as tall as
// the longest and nothing below it moves when the words change.
function Lines({ side, now, className }: { side: "left" | "right"; now: Line; className: string }) {
  return (
    <div aria-hidden="true" className={`grid text-center ${className}`}>
      {VERSIONS.map((pair, i) => {
        const l = pair[side];
        const on = l === now;
        return (
          <div
            key={i}
            className={`flex flex-col gap-2.5 transition-opacity [grid-area:1/1] ${on ? "delay-300 duration-500" : "pointer-events-none select-none opacity-0 duration-300"}`}
          >
            <div className="text-[15px] font-medium">{l.head}</div>
            <p className="text-pretty text-sm leading-relaxed text-muted">{l.text}</p>
          </div>
        );
      })}
    </div>
  );
}

// Rolls forward while the window is open; the jump back to the loop's start
// happens while it is closed, and fades instead of rolling backwards.
function Clock({ text, roll }: { text: string; roll: boolean }) {
  const time = <Roll text={text} />;
  return (
    <span className="inline-block w-[58px] whitespace-nowrap text-right tabular-nums">
      {roll ? (
        time
      ) : (
        <Swap className="block" enter="demo-in-late" text={text}>
          {time}
        </Swap>
      )}
    </span>
  );
}

// The game's own pointer. Its click point is the fingertip at its top left,
// so the press shrinks towards it.
function Cursor({ spot, shown, down }: { spot: { x: number; y: number } | null; shown: boolean; down: boolean }) {
  // Counts presses, so each one gets its own ring.
  const presses = Math.ceil(useChange(down).n / 2);
  return (
    <div
      aria-hidden="true"
      className={`pointer-events-none absolute left-0 top-0 z-20 ${shown ? "" : "opacity-0"}`}
      style={{
        translate: spot ? `${spot.x}px ${spot.y}px` : undefined,
        transition: "translate 0.6s cubic-bezier(0.65, 0, 0.35, 1), opacity 0.3s ease",
      }}
    >
      <span key={presses} className={`absolute -left-3.5 -top-3.5 size-7 rounded-full border border-white/70 ${presses ? "demo-click" : "opacity-0"}`} />
      <img
        src={gauntlet.src}
        alt=""
        width={26.5}
        height={24}
        className={`block h-6 w-[26.5px] max-w-none origin-top-left transition-[scale] duration-100 ${down ? "scale-90" : ""}`}
      />
    </div>
  );
}
