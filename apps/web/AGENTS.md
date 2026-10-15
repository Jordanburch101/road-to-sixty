# Website (apps/web)

The public site (#1): what the addon and the app do, the app's download
for the visitor's computer with the unsigned-app steps, Privacy and Terms.
Static pages built by Astro, hosted on Vercel. The design is
`docs/superpowers/specs/2026-10-15-website-design.md`; the mockups are the
"Website" row of the mockups canvas.

## Layout

- `src/pages/` are the pages: home, `download/` (one per platform),
  `privacy`, `terms`, `404`.
- `src/components/` are the home page's sections and the header, footer
  and download button. `src/layouts/Layout.astro` wraps every page.
- `src/download.ts` picks the download for the visitor's computer (the
  one script the site sends); `src/config.ts` reads the build settings.
- `src/roads.ts` holds the fog's roads. The fog itself and the theme come
  from `packages/ui`.
- `src/assets/journey/` holds the in-game screenshots of the journey map,
  at 2000 px. The build makes AVIF, WebP and JPEG copies at 1040 and 2000
  px with sharp (Astro's `<Picture>`), so keep only the full-size originals.

## Commands (from apps/web)

```
bun test
bun run typecheck   # tsc over src/**/*.ts(x): astro check refuses TypeScript 7
bun run dev         # with .env copied from .env.example
bun run build
```

## Rules that bite

- The contact email, the addon's address and the site's address are
  build settings (`.env.example`), never in the repo, which may go public.
  A missing one stops the build.
- The shared React components render at build time; no React is sent to
  the browser. Keep every animation in CSS, still under reduced motion.
- The screenshots show only Jordan's own characters. Blur any other
  player's name before adding one.
- No analytics, cookies, or fonts and scripts from other sites.
