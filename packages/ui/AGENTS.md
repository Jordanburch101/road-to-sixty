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
  or fogged for a set of roads, and how far along its road each lit dot is.
  It also holds the animation (`fogAnimation`, `fogDelay`): a lit stretch
  travelling along each road. Plain functions, tested in `dots.test.ts`.
  Each lit dot also knows its road; `Timing` gives a road its own turn in
  the loop, and `Fog`'s `colours` its own colour (the website's "one road"
  band).
- `src/Fog.tsx` draws that grid in React (`animate` makes it move; the app's
  first run leaves it still; each animated dot carries its loop length
  inline, so two fogs on one page keep their own speeds); the server's link page draws it from
  `dots.ts` without React, and the website will use it with `animate`.
  `src/Button.tsx` is the cream and outline button.
- `classes/` holds the class icons (cut from the game's UI-Classes-Circles
  by `apps/desktop/scripts/class-icons.py`), and `src/classes.ts` maps class
  file names to them, for the app and the website.
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
