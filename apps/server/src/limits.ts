// How often one PC or account may call the server, upload, restore and
// export (spec, "Limits"). The app uploads a character at most every 15
// minutes while the game runs, so these only stop a runaway app or someone
// scripting the API.
// ponytail: counted in memory by one server process, so a restart forgets
// them and a second instance wouldn't share them; move to Postgres if the
// server ever runs twice.
export class Window {
  // Each hit is [when, weight]; most weigh 1, an upload's bytes weigh its size.
  private hits = new Map<string, [number, number][]>();
  private swept = 0;

  constructor(
    readonly max: number,
    readonly seconds: number,
    private now: () => number = Date.now,
  ) {}

  // Counts the hit and says yes, or says no without counting it.
  take(key: string, weight = 1): boolean {
    this.sweep();
    const recent = this.recent(key);
    if (recent.reduce((sum, [, w]) => sum + w, 0) + weight > this.max) return false;
    recent.push([this.now(), weight]);
    this.hits.set(key, recent);
    return true;
  }

  // Whole seconds until the oldest counted hit leaves the window.
  retryAfter(key: string): number {
    const oldest = this.recent(key)[0]?.[0];
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

  private recent(key: string): [number, number][] {
    const since = this.now() - this.seconds * 1000;
    const recent = (this.hits.get(key) ?? []).filter(([t]) => t > since);
    if (recent.length === 0) this.hits.delete(key);
    else this.hits.set(key, recent);
    return recent;
  }
}

// Relinking a PC sends every character again, up to the 100 an account may
// have, so a PC gets room for all of them at once.
export const uploads = new Window(120, 15 * 60);
export const requests = new Window(600, 3600);
// Per account, so linking more PCs doesn't multiply what one account can send.
export const accountUploads = new Window(240, 15 * 60);
export const accountDaily = new Window(500, 24 * 3600);
// Every PC of an account together, so unlinking and relinking (a new PC id,
// a fresh per-PC count) doesn't get round the per-PC limits.
export const accountRequests = new Window(2000, 3600);
export const links = new Window(10, 24 * 3600);
// What an account may store in a day: an upload is about 400 KB compressed.
export const accountBytes = new Window(200 * 1024 * 1024, 24 * 3600);
// Battle.net accounts are free, so the server takes new players at a
// steady rate rather than any number at once. Keyed "all".
export const signUps = new Window(200, 3600);
// The export builds every character's journey into one zip in memory.
export const exports = new Window(5, 3600);

// Restores run the merge program inline, so at most 10 per account an hour.
export const restores = new Window(10, 3600);

// How many of a costly thing may run at once across the server. Taken
// without waiting: a caller that finds none free is told to try again.
export class Slot {
  private used = 0;
  constructor(readonly max: number) {}
  take(): boolean {
    if (this.used >= this.max) return false;
    this.used++;
    return true;
  }
  give() {
    this.used = Math.max(0, this.used - 1);
  }
  clear() {
    this.used = 0;
  }
}

// A restore's merge program can use 512 MB, and the worker may be running
// one too; an export holds every journey it zips in memory.
export const restoreSlot = new Slot(1);
export const exportSlot = new Slot(1);

export function clearLimits() {
  for (const w of [uploads, requests, accountUploads, accountDaily, accountRequests, links, accountBytes, signUps, exports, restores, restoreSlot, exportSlot]) {
    w.clear();
  }
}
