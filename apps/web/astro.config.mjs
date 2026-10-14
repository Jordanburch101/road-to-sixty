import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";

// Static pages only: the site has no server. The address is a build setting.
export default defineConfig({
  site: process.env.PUBLIC_SITE_URL,
  output: "static",
  integrations: [react()],
  vite: { plugins: [tailwindcss()] },
});
