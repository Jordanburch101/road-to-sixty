// Which download to offer: the visitor's own computer when it is a Mac,
// Windows or Linux, every one otherwise. iPads report a Mac browser, so a
// touch screen counts against it, and Android reports Linux, so phones are
// ruled out first.
export type Choice = "mac" | "windows" | "linux" | "choose";

export function pick(nav: { userAgent: string; platform?: string; maxTouchPoints?: number }): Choice {
  const ua = nav.userAgent;
  const platform = nav.platform ?? "";
  if (/iPhone|iPad|iPod|Android/i.test(ua)) return "choose";
  if (/Windows/i.test(ua) || /^Win/i.test(platform)) return "windows";
  if (/Macintosh/i.test(ua) || /^Mac/i.test(platform)) return (nav.maxTouchPoints ?? 0) > 1 ? "choose" : "mac";
  if (/Linux/i.test(ua) || /^Linux/i.test(platform)) return "linux";
  return "choose";
}

export const LABEL: Record<Choice, string> = {
  mac: "Download for macOS",
  windows: "Download for Windows",
  linux: "Download for Linux (early)",
  choose: "Download for Mac, Windows or Linux",
};

// The line under the button: the two other systems, on the page with every download.
export const ALSO: Record<Exclude<Choice, "choose">, string> = {
  mac: "Windows and Linux",
  windows: "Mac and Linux",
  linux: "Mac and Windows",
};

export const PAGE: Record<Choice, string> = {
  mac: "/download/mac",
  windows: "/download/windows",
  linux: "/download/linux",
  choose: "/download",
};

// Points every [data-download] button at this computer's download, and the
// "also for" line at the other two. Without this, the page offers all three.
export function wireDownloads() {
  const data = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData;
  const choice = pick({ userAgent: navigator.userAgent, platform: data?.platform ?? navigator.platform, maxTouchPoints: navigator.maxTouchPoints });
  for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-download]")) {
    a.href = PAGE[choice];
    const label = a.querySelector<HTMLElement>("[data-label]");
    if (label) label.textContent = LABEL[choice];
    for (const icon of a.querySelectorAll<SVGElement>("[data-icon]")) icon.toggleAttribute("hidden", icon.dataset.icon !== choice);
  }
  for (const line of document.querySelectorAll<HTMLElement>("[data-also]")) {
    if (choice === "choose") continue;
    const link = line.querySelector<HTMLAnchorElement>("a")!;
    link.href = PAGE.choose;
    link.textContent = ALSO[choice];
    line.hidden = false;
  }
}
