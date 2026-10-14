// Build settings, from Vercel's environment (or .env locally). The build
// stops when one is missing, rather than shipping an empty link.
export function need(name: string, value: string | undefined): string {
  if (!value) throw new Error(`${name} isn't set: see apps/web/.env.example`);
  return value;
}

const env = import.meta.env ?? {};
export const DOWNLOADS: string = env.PUBLIC_DOWNLOADS || "https://dl.rts.everhold.online";

// Read when a page uses them, so the tests can load this file without them.
export const addonUrl = () => need("PUBLIC_ADDON_URL", env.PUBLIC_ADDON_URL);
export const contactEmail = () => need("PUBLIC_CONTACT_EMAIL", env.PUBLIC_CONTACT_EMAIL);

// The fixed names the app's release workflow uploads (desktop-release.yml).
export function fileUrl(platform: "mac" | "windows"): string {
  return `${DOWNLOADS}/app/${platform === "mac" ? "Road-to-Sixty.dmg" : "Road-to-Sixty-Setup.exe"}`;
}
