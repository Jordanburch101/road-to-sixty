import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

// The small moving pieces the app demo's screens share. The classes they use
// (demo-in, demo-out, demo-roll-in and so on) are in site.css.

// What was shown before, and how many times it has changed. Keys made from n
// remount the old and new copies, which starts their animations.
export function useChange<T>(value: T) {
  const [s, setS] = useState<{ now: T; was: T | null; n: number }>({ now: value, was: null, n: 0 });
  if (s.now === value) return s;
  const next = { now: value, was: s.now, n: s.n + 1 };
  setS(next);
  return next;
}

// Text that fades from one wording to the next. The old copy is taken out of
// the flow, so the new one decides the size; with fit, the box grows or
// shrinks to it instead of jumping. children, when given, draw the new copy.
export function Swap({ text, className = "", enter = "demo-in", fit = false, children }: { text: string; className?: string; enter?: string; fit?: boolean; children?: ReactNode }) {
  const s = useChange(text);
  const now = useRef<HTMLSpanElement>(null);
  const [width, setWidth] = useState<number>();
  useLayoutEffect(() => {
    if (fit) setWidth(now.current!.getBoundingClientRect().width);
  }, [text, fit]);
  return (
    <span className={`relative ${className}`} style={fit && s.n ? { width } : undefined}>
      {s.was !== null && (
        <span key={`was${s.n}`} className="demo-out absolute inset-x-0 top-0">
          {s.was}
        </span>
      )}
      <span ref={now} key={`now${s.n}`} className={`inline-block ${s.n ? enter : ""}`}>
        {children ?? text}
      </span>
    </span>
  );
}

// A number or time that rolls like a counter: each character that changes
// slides up and out as the new one slides in.
export function Roll({ text }: { text: string }) {
  return (
    <span className="inline-flex">
      {[...text].map((c, i) => (
        <RollChar key={i} c={c} />
      ))}
    </span>
  );
}

function RollChar({ c }: { c: string }) {
  const s = useChange(c);
  return (
    <span className="relative inline-block whitespace-pre [clip-path:inset(0_-4px)]">
      {s.was !== null && (
        <span key={`was${s.n}`} className="demo-roll-out absolute left-0 top-0">
          {s.was}
        </span>
      )}
      <span key={`now${s.n}`} className={`inline-block ${s.n ? "demo-roll-in" : ""}`}>
        {c}
      </span>
    </span>
  );
}

// Opens and folds its contents smoothly. Spacing above the contents belongs
// inside, so a folded part takes no room at all.
export function Fold({ open, children }: { open: boolean; children: ReactNode }) {
  return (
    <div
      className={`grid transition-[grid-template-rows,opacity] duration-300 ease-out ${open ? "grid-rows-[1fr]" : "grid-rows-[0fr] opacity-0"}`}
    >
      <div className="min-h-0 overflow-hidden">{children}</div>
    </div>
  );
}
