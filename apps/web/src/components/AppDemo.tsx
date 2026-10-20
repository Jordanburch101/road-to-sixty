import compass from "@road-to-sixty/ui/compass.png";
import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import arrow from "../assets/demo/cursor-arrow.png";
import gauntlet from "../assets/demo/cursor-gauntlet.png";
import { advance, demoAt, LINES, LOOP, STILL, STILL_LINES, type Demo, type Line } from "../demo";
import { DemoCharacters } from "./DemoCharacters";
import { DemoSetup, type Buttons } from "./DemoSetup";
import { Roll, useChange } from "./DemoMotion";

// The home page's app demo (docs/superpowers/specs/2026-10-20-app-demo-design.md):
// the still picture in the page's HTML, then, once half of it is on screen, the
// story from demo.ts on a loop. Every change moves through CSS; this only keeps time.

const STORY =
  "The Road to Sixty app opening under its menu bar icon. It sets itself up in three clicks: it installs the addon, links this PC, and asks you to restart WoW once. Then its list fills with your characters from every PC, one levels up after a session, and a new character joins, each backed up as it changes.";

// The still picture's rows close with the window before the loop's first turn.
const CLOSING: Demo = { ...STILL, open: false, lit: false };

const view = (t: number | null, wrapped: boolean, phone: boolean) => (t === null ? STILL : wrapped ? demoAt(t, phone) : CLOSING);

// Each art's click point, in CSS pixels from its top left.
const CURSORS = {
  arrow: { src: arrow.src, width: 12, height: 18, x: 2.5, y: 2.5 },
  gauntlet: { src: gauntlet.src, width: 26.5, height: 24, x: 0, y: 0 },
};

export function AppDemo({ cursor = "arrow" }: { cursor?: "arrow" | "gauntlet" }) {
  const [t, setT] = useState<number | null>(null);
  const [wrapped, setWrapped] = useState(false);
  const [phone, setPhone] = useState(false);
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const reduce = matchMedia("(prefers-reduced-motion: reduce)");
    const narrow = matchMedia("(max-width: 767px)");
    let time = 0;
    let wrap = false;
    let started = false;
    let seen = false;
    let frame = 0;
    let last = 0;
    let shown = "";

    // React hears about a frame only when what it shows changes.
    const show = () => {
      const now = JSON.stringify(view(time, wrap, narrow.matches));
      if (now === shown) return;
      shown = now;
      setT(time);
      setWrapped(wrap);
    };
    const tick = (now: number) => {
      time = advance(time, last ? now - last : 0);
      last = now;
      if (time >= LOOP) {
        time %= LOOP;
        wrap = true;
      }
      show();
      frame = requestAnimationFrame(tick);
    };
    const run = () => {
      const go = seen && !document.hidden && !reduce.matches;
      if (go && !frame) {
        if (!started) {
          started = true;
          time = LOOP - 1;
          wrap = false;
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
        setT(null);
        setWrapped(false);
      }
      run();
    };
    const onNarrow = () => setPhone(narrow.matches);
    const seeing = new IntersectionObserver(
      ([e]) => {
        seen = e!.intersectionRatio >= 0.5;
        run();
      },
      { threshold: 0.5 },
    );

    onNarrow();
    seeing.observe(root.current!);
    reduce.addEventListener("change", onReduce);
    narrow.addEventListener("change", onNarrow);
    document.addEventListener("visibilitychange", run);
    return () => {
      seeing.disconnect();
      reduce.removeEventListener("change", onReduce);
      narrow.removeEventListener("change", onNarrow);
      document.removeEventListener("visibilitychange", run);
      cancelAnimationFrame(frame);
    };
  }, []);

  const demo = view(t, wrapped, phone);
  const still = t === null || !wrapped;
  const lines = t === null ? STILL_LINES : LINES[demo.part];
  const pressed = demo.cursor.down ? demo.cursor.at : null;

  const icon = useRef<HTMLSpanElement>(null);
  const win = useRef<HTMLDivElement>(null);
  const buttons: Buttons = { install: useRef(null), link: useRef(null), done: useRef(null) };
  const [spot, setSpot] = useState<{ x: number; y: number } | null>(null);
  const { at, shown } = demo.cursor;
  useLayoutEffect(() => {
    const place = () => {
      const r = root.current!.getBoundingClientRect();
      const target = at === "icon" ? icon.current : buttons[at].current;
      if (shown && target) {
        const b = target.getBoundingClientRect();
        setSpot({ x: b.left + b.width / 2 - r.left, y: b.top + b.height / 2 - r.top });
      } else if (!shown && at === "icon") {
        // Parked over the window's lower right while hidden, so it glides in to its first target.
        const w = win.current!.getBoundingClientRect();
        setSpot({ x: w.right - r.left - 70, y: w.top - r.top + 380 });
      }
    };
    place();
    addEventListener("resize", place);
    return () => removeEventListener("resize", place);
  }, [at, shown, phone]);

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
            ref={icon}
            className={`flex size-[22px] items-center justify-center rounded-[5px] transition-[background-color,scale,filter] duration-200 ${demo.lit ? "bg-accent/20" : ""} ${pressed === "icon" ? "scale-90 brightness-90" : ""}`}
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
          <DemoSetup demo={demo} still={still} shown={demo.screen === "setup"} pressed={pressed} buttons={buttons} />
          <DemoCharacters demo={demo} still={still} shown={demo.screen === "characters"} />
        </div>
      </div>

      <Lines side="right" now={lines.right} className="order-3 md:pt-[330px] md:text-left" />

      <div className="sr-only">
        {Object.values(LINES).map((pair) => (
          <Fragment key={pair.left.head}>
            <h2>{pair.left.head}</h2>
            <p>{pair.left.text}</p>
            <h2>{pair.right.head}</h2>
            <p>{pair.right.text}</p>
          </Fragment>
        ))}
      </div>

      <Cursor art={CURSORS[cursor]} spot={spot} shown={shown} down={demo.cursor.down} />
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
  const [s, setS] = useState({ text, fades: 0, was: null as string | null });
  let now = s;
  if (text !== s.text) {
    now = roll ? { ...s, text } : { text, fades: s.fades + 1, was: s.text };
    setS(now);
  }
  return (
    <span className="relative inline-block w-[58px] text-right tabular-nums">
      {now.was !== null && (
        <span key={`was${now.fades}`} className="demo-out absolute inset-0">
          {now.was}
        </span>
      )}
      <span key={`now${now.fades}`} className={`inline-block ${now.fades ? "demo-in-late" : ""}`}>
        <Roll text={now.text} />
      </span>
    </span>
  );
}

function Cursor({ art, spot, shown, down }: { art: (typeof CURSORS)["arrow"]; spot: { x: number; y: number } | null; shown: boolean; down: boolean }) {
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
        src={art.src}
        alt=""
        width={art.width}
        height={art.height}
        className={`block max-w-none transition-[scale] duration-100 ${down ? "scale-90" : ""}`}
        style={{ width: art.width, height: art.height, translate: `${-art.x}px ${-art.y}px`, transformOrigin: `${art.x}px ${art.y}px` }}
      />
    </div>
  );
}
