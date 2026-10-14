// The link page's script, built for the browser by link.ts and typechecked
// with the browser's types by tsconfig.page.json. The app's link fills the
// code in (Jordan's call, 2026-10-14): easier, but a link with someone
// else's code works too, so the page shows whose PC it is and asks the
// player to check the code against their app.
import { fogAnimation, fogDelay, fogDots, type Point } from "@road-to-sixty/ui/dots";

const $ = (id: string) => document.getElementById(id)!;
const SVG = "http://www.w3.org/2000/svg";
const LOOP = 14;
const ROAD: Point[] = [[-20, 300], [220, 250], [420, 190], [620, 170], [820, 110], [1040, 80], [1420, 20]];
const PLATFORMS: Record<string, string> = { darwin: "Mac", windows: "Windows", linux: "Linux" };

// The fog spans the whole window however wide it is, the road stretched to
// fit, so its edges never show as a box.
function drawFog() {
  const svg = $("fog");
  const width = Math.max(document.documentElement.clientWidth, 320);
  svg.setAttribute("width", String(width));
  svg.setAttribute("viewBox", `0 0 ${width} 360`);
  svg.replaceChildren();
  const style = document.createElementNS(SVG, "style");
  style.textContent = fogAnimation(LOOP);
  svg.append(style);
  const road = ROAD.map(([x, y]): Point => [(x * width) / 1400, y]);
  const { lit, edge, fog } = fogDots(width, 360, 18, [road]);
  const dot = (x: number, y: number, r: number, fill: string, at?: number) => {
    const c = document.createElementNS(SVG, "circle");
    c.setAttribute("cx", String(x));
    c.setAttribute("cy", String(y));
    c.setAttribute("r", String(r));
    c.setAttribute("fill", fill);
    if (at !== undefined) {
      c.setAttribute("class", "rts-fog-road");
      c.style.animationDelay = fogDelay(at, LOOP);
    }
    svg.append(c);
  };
  for (const [x, y] of fog) dot(x, y, 1.1, "rgba(154,149,168,0.14)");
  for (const [x, y, at] of edge) dot(x, y, 1.4, "rgba(154,149,168,0.38)", at);
  for (const [x, y, at] of lit) dot(x, y, 1.8, "rgba(58,160,255,0.85)", at);
}

async function call(path: string, body?: object) {
  const r = await fetch(`/api/auth${path}`, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : {});
  return { ok: r.ok, data: await r.json().catch(() => null) };
}

// The name the app sent with its code, if it sent one (app 0.1.1 doesn't).
function pcOf(scope: unknown): string | null {
  try {
    const { pc, platform } = JSON.parse(String(scope)) as { pc?: unknown; platform?: unknown };
    if (typeof pc !== "string" || !pc) return null;
    const where = typeof platform === "string" ? PLATFORMS[platform] : undefined;
    return where ? `${pc} · ${where}` : pc;
  } catch {
    return null;
  }
}

const typed = () => ($("code") as HTMLInputElement).value.toUpperCase().replace(/[^A-Z0-9]/g, "");

drawFog();
let resized: ReturnType<typeof setTimeout> | undefined;
addEventListener("resize", () => {
  clearTimeout(resized);
  resized = setTimeout(drawFog, 150);
});
const signedIn = (await call("/get-session")).data as { user: { name: string } } | null;
if (!signedIn) {
  $("sign-in").hidden = false;
  $("sign-in").onclick = async () => {
    const r = await call("/sign-in/social", { provider: "battlenet", callbackURL: location.pathname + location.search });
    if (r.data?.url) location.href = r.data.url;
  };
} else {
  $("who").textContent = `Signed in as ${signedIn.user.name}`;
  $("form").hidden = false;
  let looked = "";
  // Looking the code up ties it to this player; only then is the PC's name
  // shown, and only then can they approve it.
  $("code").oninput = async () => {
    const code = typed();
    if (code.length < 8 || code === looked) return;
    looked = code;
    const found = await call(`/device?user_code=${encodeURIComponent(code)}`);
    const name = found.ok ? pcOf(found.data?.scope) : null;
    $("pc").hidden = !found.ok;
    $("pc-name").textContent = name ?? "a PC";
    $("link").textContent = name ? `Link ${name.split(" · ")[0]}` : "Link";
  };
  const given = new URLSearchParams(location.search).get("user_code");
  if (given) {
    ($("code") as HTMLInputElement).value = given;
    void ($("code").oninput as () => Promise<void>)();
  }
  $("form").onsubmit = async (e) => {
    e.preventDefault();
    const userCode = typed();
    const found = await call(`/device?user_code=${encodeURIComponent(userCode)}`);
    const r = found.ok ? await call("/device/approve", { userCode }) : found;
    $("result").textContent = r.ok
      ? "Linked. You can close this page; the app takes it from here."
      : `That didn't work: ${r.data?.message ?? "check the code and try again"}`;
  };
}
