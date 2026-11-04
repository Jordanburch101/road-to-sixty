// The animated headers for the CurseForge description, drawn with the
// website's fog of war (packages/ui/src/dots.ts) and recorded to looping GIFs
// next to this file. Needs ffmpeg and a Chromium for playwright-core: run
// `bunx playwright-core install chromium` once, or point CHROME at a browser.
//
//   bun branding/curseforge-header.ts [hero] [classes]
//
//   curseforge-header.gif           two blue roads, as the website's hero
//   curseforge-header-classes.gif   nine roads in the class colours
import { chromium } from "playwright-core";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { fogAnimation, fogDelay, fogDots, onGrid, type Point, type Timing } from "../packages/ui/src/dots";
import { CLASSES } from "../packages/ui/src/classColours";

const UI = `${import.meta.dir}/../packages/ui`;
const FONT = Bun.resolveSync("@fontsource-variable/geist/files/geist-latin-wght-normal.woff2", `${UI}/src`);
const COMPASS = `file://${UI}/compass.png`;
const WORK = `${import.meta.dir}/video/curseforge-header`;
const W = 1200, H = 400, FPS = 25;
const ACCENT = "#3aa0ff";

// The website's random walk (apps/web/src/roads.ts), at this size.
function seeded(seed: number) {
  let s = seed | 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function walk(rnd: () => number, x: number, y: number, a: number, steps: number, len: number): Point[] {
  const pts: Point[] = [[x, y]];
  for (let i = 0; i < steps; i++) {
    a += (rnd() - 0.5) * 0.9;
    if (x < 30 || x > W - 30 || y < 30 || y > H - 30) {
      const back = Math.atan2(H / 2 - y, W / 2 - x);
      a += Math.atan2(Math.sin(back - a), Math.cos(back - a)) * 0.3;
    }
    x += Math.cos(a) * len;
    y += Math.sin(a) * len;
    pts.push([x, y]);
  }
  return pts;
}

// The same SVG as Fog.tsx, as a string, looping every `loop` seconds.
function fog(loop: number, step: number, roads: Point[][], colours?: string[], timing?: Timing[]) {
  const { lit, edge } = fogDots(W, H, step, roads, timing);
  const d = (at: number) => `class="rts-fog-road" style="animation-delay:${fogDelay(at, loop)}"`;
  return `<svg width="${W}" height="${H}" style="position:absolute;inset:0">
<style>${fogAnimation(loop)}</style>
<pattern id="g" width="${step}" height="${step}" patternUnits="userSpaceOnUse"><circle cx="${step / 2}" cy="${step / 2}" r="1.1" fill="rgba(154,149,168,0.16)"/></pattern>
<rect width="${W}" height="${H}" fill="url(#g)"/>
${edge.map(([x, y, at]) => `<circle cx="${x}" cy="${y}" r="1.4" fill="rgba(154,149,168,0.4)" ${d(at)}/>`).join("")}
${lit.map(([x, y, at, r]) => `<circle cx="${x}" cy="${y}" r="1.8" fill="${colours?.[r] ?? ACCENT}" fill-opacity="0.85" ${d(at)}/>`).join("")}
</svg>`;
}

// The title in a dark pool in the middle, over the fog.
const page = (background: string, subtitle: string) => `<!doctype html><meta charset="utf-8"><style>
@font-face{font-family:Geist;src:url("file://${FONT}")}
body{margin:0;background:#07060a}
.f{position:relative;width:${W}px;height:${H}px;overflow:hidden;color:#ece9f2;font-family:Geist,sans-serif}
.f::after{content:"";position:absolute;inset:0;border:1px solid #1f1d26}
h1{margin:0;font-weight:500;font-size:64px;letter-spacing:-.035em;line-height:1}
p{margin:16px 0 0;color:#9a95a8;font-size:21px}
/* The compass is drawn on black: screen drops the black, the mask its square edge. */
.compass{mix-blend-mode:screen;-webkit-mask-image:radial-gradient(circle,#000 52%,transparent 70%)}
</style><div class="f">${background}
<div style="position:absolute;inset:0;background:radial-gradient(ellipse 430px 145px at 50% 50%,rgba(7,6,10,.96) 0%,rgba(7,6,10,.7) 55%,transparent 100%)"></div>
<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center">
  <div style="display:flex;align-items:center;gap:18px"><img class="compass" src="${COMPASS}" width="72" height="72"><h1>Road to Sixty</h1></div>
  <p>${subtitle}</p>
</div></div>`;

const headers: Record<string, { file: string; loop: number; html: () => string }> = {
  hero: {
    file: "curseforge-header.gif",
    loop: 8,
    html() {
      const rnd = seeded(11);
      const roads = [walk(rnd, -20, 300, -0.25, 70, 22), walk(rnd, W + 20, 70, Math.PI + 0.25, 70, 22)];
      const marks = roads.flatMap((r) => r.filter((_, i) => i >= 6 && (i - 6) % 12 === 0)).map((m) => onGrid(m, 16));
      const rings = marks.map(([x, y]) =>
        `<circle cx="${x}" cy="${y}" r="8" fill="none" stroke="${ACCENT}" stroke-opacity=".35"/><circle cx="${x}" cy="${y}" r="3" fill="${ACCENT}"/>`);
      return page(`${fog(this.loop, 16, roads)}<svg width="${W}" height="${H}" style="position:absolute;inset:0">${rings.join("")}</svg>`,
        "Your road from level 1 to 60, replayed on the map");
    },
  },
  // Each road starts on one of the four edges, heading in, and lights in its
  // own turn, so several are always moving in different places.
  classes: {
    file: "curseforge-header-classes.gif",
    loop: 10,
    html() {
      const keys = Object.keys(CLASSES);
      const rnd = seeded(23);
      const roads = keys.map((_, i) => {
        const t = 0.1 + rnd() * 0.8;
        const [x, y, a] = ([[t * W, -20, Math.PI / 2], [W + 20, t * H, Math.PI], [t * W, H + 20, -Math.PI / 2], [-20, t * H, 0]] as const)[i % 4];
        return walk(rnd, x, y, a + (rnd() - 0.5) * 0.8, 55, 22);
      });
      const timing = keys.map((_, i) => ({ start: i / keys.length, share: 0.6 }));
      return page(fog(this.loop, 15, roads, keys.map((k) => CLASSES[k]!.colour), timing), "Every class, every road, from level 1 to 60");
    },
  },
};

const chosen = process.argv.length > 2 ? process.argv.slice(2) : Object.keys(headers);
const browser = await chromium.launch({ executablePath: process.env.CHROME, args: ["--allow-file-access-from-files"] });
for (const name of chosen) {
  const { file, loop, html } = headers[name] ?? (() => { throw new Error(`no header called ${name}`); })();
  const dir = `${WORK}/${name}`;
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/page.html`, html.call(headers[name]));
  // Drawn at twice the size and scaled down, for smoother dots and text.
  const tab = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 2 });
  await tab.goto(`file://${dir}/page.html`);
  await tab.evaluate(() => document.fonts.ready);
  // Every dot runs the same loop, so frames 0 to loop seconds join up seamlessly.
  // The extra loop keeps dots with a positive delay (late roads) already running.
  for (let i = 0; i < loop * FPS; i++) {
    const ms = (i / FPS + loop) * 1000;
    await tab.evaluate((ms) => document.getAnimations().forEach((a) => { a.pause(); a.currentTime = ms; }), ms);
    await tab.screenshot({ path: `${dir}/${String(i).padStart(4, "0")}.png` });
  }
  await tab.close();
  const gif = `${import.meta.dir}/${file}`;
  // An ordered (bayer) dither stays still between frames, where error diffusion shimmers.
  const ff = Bun.spawnSync(["ffmpeg", "-v", "error", "-y", "-framerate", String(FPS), "-i", `${dir}/%04d.png`, "-vf",
    `scale=${W}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`,
    "-loop", "0", gif]);
  if (ff.exitCode) throw new Error(ff.stderr.toString());
  console.log(`${file} ${(Bun.file(gif).size / 1e6).toFixed(1)} MB`);
}
await browser.close();
