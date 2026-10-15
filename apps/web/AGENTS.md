# Website (apps/web)

The public site (#1): what the addon and the app do, the app's download
for the visitor's computer (Mac, Windows, or Linux for the Steam Deck in
Desktop Mode, early, #47) with the first-run steps, Privacy and Terms.
Static pages built by Astro, hosted on Vercel. The design is
`docs/superpowers/specs/2026-10-15-website-design.md`; the mockups are the
"Website" row of the mockups canvas.

## Layout

- `src/pages/` are the pages: home, `download/` (one per platform),
  `privacy`, `terms`, `404`.
- `src/components/` are the home page's sections and the header, footer
  and download button. `src/layouts/Layout.astro` wraps every page.
- `src/download.ts` picks the download for the visitor's computer, and
  `src/countdown.ts` runs the flip board counting down to launch: the
  only scripts the site sends, besides the two short ones in `Layout.astro`
  for the load-in animation (`src/styles/reveal.css`).
  `src/config.ts` reads the build settings.
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
  build settings (`.env.example`), never in the public repo.
  A missing one stops the build, and so does an address without https://.
- The shared React components render at build time; no React is sent to
  the browser. Keep every animation in CSS, still under reduced motion.
- Content rises into place as it reaches the screen: each child of a
  `[data-reveal]` element that isn't `[data-reveal]` itself. `<body>` has
  it, so a new section rises as one block; give it `data-reveal` to bring
  in its pieces one by one, or `data-grow` to grow in like the map. A
  `display: contents` wrapper needs `data-reveal` too (Launch's), or it is
  a part that can't fade. A part's own `transition` is set aside only
  while it rises.
- The screenshots show only Jordan's own characters. Blur any other
  player's name before adding one.
- No cookies, and no fonts or scripts from other sites. The one exception
  to "no tracking" is Vercel Web Analytics (`<Analytics />` in Layout.astro),
  which sets no cookies and loads from the site's own address; the Privacy
  page says so. Add nothing else that counts visitors.
