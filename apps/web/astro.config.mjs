import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";

// Static pages only: the site has no server. The address is a build setting:
// Vercel's environment, or .env locally (which this file doesn't get on its
// own, unlike the pages).
try {
  process.loadEnvFile();
} catch {}
if (!URL.canParse(process.env.PUBLIC_SITE_URL ?? "")) throw new Error("PUBLIC_SITE_URL isn't set: see apps/web/.env.example");

export default defineConfig({
  site: process.env.PUBLIC_SITE_URL,
  output: "static",
  integrations: [react()],
  vite: { plugins: [tailwindcss()] },
});
