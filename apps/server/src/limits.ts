// How often one PC may call the server (spec, "Limits"). The app uploads a
// character at most every 15 minutes while the game runs, so these only
// stop a runaway app or someone scripting the API.
// ponytail: counted in memory by one server process, so a restart forgets
// them and a second instance wouldn't share them; move to Postgres if the
// server ever runs twice.
export class Window {
  private hits = new Map<string, number[]>();
  private swept = 0;

  constructor(
    readonly max: number,
    readonly seconds: number,
    private now: () => number = Date.now,
  ) {}

  // Counts the hit and says yes, or says no without counting it.
  take(key: string): boolean {
    this.sweep();
    const recent = this.recent(key);
    if (recent.length >= this.max) return false;
    recent.push(this.now());
    this.hits.set(key, recent);
    return true;
  }

  // Whole seconds until the oldest counted hit leaves the window.
  retryAfter(key: string): number {
    const oldest = this.recent(key)[0];
    return oldest === undefined ? 0 : Math.ceil((oldest + this.seconds * 1000 - this.now()) / 1000);
  }

  get size() {
    return this.hits.size;
  }

  clear() {
    this.hits.clear();
  }

  // Once per window, drops every key whose hits have all expired, so the map
  // doesn't grow with every PC that ever called.
  private sweep() {
    if (this.now() - this.swept < this.seconds * 1000) return;
    this.swept = this.now();
    for (const key of [...this.hits.keys()]) this.recent(key);
  }

  private recent(key: string): number[] {
    const since = this.now() - this.seconds * 1000;
    const recent = (this.hits.get(key) ?? []).filter((t) => t > since);
    if (recent.length === 0) this.hits.delete(key);
    else this.hits.set(key, recent);
    return recent;
  }
}

export const uploads = new Window(30, 15 * 60);
export const requests = new Window(600, 3600);
// Per account, so linking more PCs doesn't multiply what one account can send.
export const accountUploads = new Window(60, 15 * 60);
export const accountDaily = new Window(500, 24 * 3600);
// The export builds every character's journey into one zip in memory.
export const exports = new Window(5, 3600);

export function clearLimits() {
  for (const w of [uploads, requests, accountUploads, accountDaily, exports]) w.clear();
}
