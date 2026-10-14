# Shared look (packages/ui)

The look the desktop app's window and the website share: look A from the
mockups Jordan picked on 2026-10-14 (near-black, thin borders, cream main
button, blue only for status, fog of war background).

## Layout

- `theme.css` holds the colours and fonts as Tailwind 4 `@theme` tokens
  (`bg-ground`, `text-muted`, `bg-cream`, `font-mono` and so on) and loads
  Geist and Geist Mono. A page imports Tailwind, then this file, then adds
  `@source` pointing at `packages/ui/src` so the classes used here are built.
- `src/dots.ts` works out the fog of war grid: which dots are lit, half lit
  or fogged for a set of roads. Plain functions, tested in `dots.test.ts`.
- `src/Fog.tsx` draws that grid; `src/Button.tsx` is the cream and outline
  button.
- `compass.png` is Jordan's compass icon (256 px, used as is). If Blizzard
  ever objects to it, this is the one file to swap.

## Commands (from packages/ui)

```
bun test
bun run typecheck
```

## Rules that bite

- Never give two files names that differ only in case (`fog.ts` and
  `Fog.tsx` clashed): macOS and Windows treat them as one file.
- Blue (`accent`) is for sync status, the setup tick and the lit fog only;
  the main action on a screen is the cream button.
- Icons are raster art or the game's own: Jordan finds drawn SVG icons look
  amateur.
