// How often one PC may call the server (spec, "Limits"). The app uploads a
// character at most every 15 minutes while the game runs, so these only
// stop a runaway app or someone scripting the API.
// ponytail: counted in memory by one server process, so a restart forgets
// them and a second instance wouldn't share them; move to Postgres if the
// server ever runs twice.
export class Window {
  private hits = new Map<string, number[]>();

  constructor(
    readonly max: number,
    readonly seconds: number,
    private now: () => number = Date.now,
  ) {}

  // Counts the hit and says yes, or says no without counting it.
  take(key: string): boolean {
    const recent = this.recent(key);
    if (recent.length >= this.max) return false;
    recent.push(this.now());
    return true;
  }

  // Whole seconds until the oldest counted hit leaves the window.
  retryAfter(key: string): number {
    const oldest = this.recent(key)[0];
    return oldest === undefined ? 0 : Math.ceil((oldest + this.seconds * 1000 - this.now()) / 1000);
  }

  clear() {
    this.hits.clear();
  }

  private recent(key: string): number[] {
    const since = this.now() - this.seconds * 1000;
    const recent = (this.hits.get(key) ?? []).filter((t) => t > since);
    this.hits.set(key, recent);
    return recent;
  }
}

export const uploads = new Window(30, 15 * 60);
export const requests = new Window(600, 3600);
