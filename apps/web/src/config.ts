// Build settings, from Vercel's environment (or .env locally). The build
// stops when one is missing, rather than shipping an empty link.
export function need(name: string, value: string | undefined): string {
  if (!value) throw new Error(`${name} isn't set: see apps/web/.env.example`);
  return value;
}

// A link setting without https:// would turn into a link within the site,
// and a trailing slash into a double one in the download addresses.
export function link(name: string, value: string | undefined): string {
  const url = need(name, value);
  if (!URL.canParse(url)) throw new Error(`${name} must be a full address, like https://...`);
  return url.replace(/\/+$/, "");
}

const env = import.meta.env ?? {};
export const DOWNLOADS: string = link("PUBLIC_DOWNLOADS", env.PUBLIC_DOWNLOADS || "https://dl.roadtosixty.online");

// Read when a page uses them, so the tests can load this file without them.
export const addonUrl = () => link("PUBLIC_ADDON_URL", env.PUBLIC_ADDON_URL);
export const contactEmail = () => need("PUBLIC_CONTACT_EMAIL", env.PUBLIC_CONTACT_EMAIL);

// The fixed names the app's release workflow uploads (desktop-release.yml).
const FILES = { mac: "Road-to-Sixty.dmg", windows: "Road-to-Sixty-Setup.exe", linux: "Road-to-Sixty.AppImage" };
export function fileUrl(platform: keyof typeof FILES): string {
  return `${DOWNLOADS}/app/${FILES[platform]}`;
}
