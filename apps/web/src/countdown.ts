// The flip board counting down to launch, and the switch to the launch-day
// text once it has passed (Launch.astro).

// 3 pm Pacific on 4 November. US clocks go back on 1 November, so Pacific is
// UTC-8 that day; if Blizzard meant 3 pm PDT, this is an hour late.
export const LAUNCH = Date.UTC(2026, 10, 4, 23);

// Days, hours, minutes and seconds left as eight digits ("DDHHMMSS"),
// zero once launch has passed.
export function digits(msLeft: number): string {
  const s = Math.max(0, Math.floor(msLeft / 1000));
  const two = (n: number) => String(Math.min(n, 99)).padStart(2, "0");
  return two(Math.floor(s / 86400)) + two(Math.floor(s / 3600) % 24) + two(Math.floor(s / 60) % 60) + two(s % 60);
}

// Each tile holds four copies of its digit: the still top and bottom halves,
// and the two halves that fold over them (site.css). A change shows the new
// top behind the old top folding down, then the new bottom folding into place.
function show(tile: HTMLElement, digit: string, still: boolean) {
  if (tile.dataset.v === digit) return;
  const old = tile.dataset.v ?? "";
  tile.dataset.v = digit;
  const halves = tile.querySelectorAll<HTMLElement>("[data-half]");
  // Still top, still bottom, folding top, folding bottom.
  [digit, still ? digit : old, old, digit].forEach((text, i) => (halves[i]!.textContent = text));
  if (still) return;
  tile.classList.remove("flip");
  void tile.offsetWidth; // restarts the animation when the same tile flips again a second later
  tile.classList.add("flip");
}

export function wireCountdown() {
  const board = document.querySelector<HTMLElement>("[data-countdown]");
  if (!board) return;
  const tiles = [...board.querySelectorAll<HTMLElement>("[data-tile]")];
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const tick = () => {
    const left = LAUNCH - Date.now();
    if (left <= 0) {
      for (const el of document.querySelectorAll<HTMLElement>("[data-before-launch]")) el.hidden = true;
      for (const el of document.querySelectorAll<HTMLElement>("[data-after-launch]")) el.hidden = false;
      clearInterval(timer);
      return;
    }
    const now = digits(left);
    tiles.forEach((tile, i) => show(tile, now.charAt(i), still));
  };
  const timer = setInterval(tick, 1000);
  tick();
}
