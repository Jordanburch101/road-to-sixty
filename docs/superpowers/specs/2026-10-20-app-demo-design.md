# Website: the app demo

The home page's app section (#60) becomes a short looping demo of the app instead of a still picture. It plays the whole first run, then the app at work: characters arriving, a level up after a session, a new character joining. It replaces item 3 of the home page in `2026-10-15-website-design.md`, and that design's "no React sent to the browser" rule for this one section.

## What it is for

A player scrolling the home page should see in a few seconds that setting the app up is three clicks, done once, and that afterwards it looks after every character on every PC by itself. The still picture only shows the end result.

Success: someone who watches one loop could set the app up without reading anything else, the demo looks like the real app, and it costs the page nothing until it scrolls into view.

Failure, even if it works: anything that snaps into place instead of moving, a demo that looks like a different app, the page jumping as the demo changes size, or a loop that keeps running while nobody can see it.

## Decisions (Jordan, 2026-10-20)

- **The whole setup, then the app at work**, in the order of the storyboard below.
- **The browser sign-in step is left out.** Clicking "Link this PC" goes straight to linked. Neither a browser window nor "Waiting for your browser" is shown.
- **Every step and every small change inside a step is animated**: the cursor gliding to each button and the button pressing, ticks popping in, titles fading from one to the next, steps opening and closing smoothly, the name typing itself in. Nothing snaps.
- **A React island is fine.** It is a fake demo with made-up data.
- **The two lines beside the window change with each part**, with the words in the table below. Their headings have no full stop, like the still picture's and the site's other small headings.
- It starts when it scrolls into view, loops, and stands still for anyone who asks for reduced motion. On phones the menu bar strip stays hidden, as it is now.

## Built as a copy, not from the app's screens (my call)

The demo is drawn by hand in `apps/web` from the shared theme, `Button`, `Fog`, `compass.png` and the class icons in `packages/ui`, the same way `AppPicture.astro` is now. It is not built from the app's own `FirstRun.tsx` and `Characters.tsx`. Those screens run fine in a browser with made-up data (tried with Tauri's `mockIPC` on 2026-10-20), but they have no animation at all. Each change of state swaps the page in a single frame. Animating every small change would mean either changing the app's screens for the website's sake, or reaching into their markup from outside, which breaks the next time anyone edits them.

The cost is that the copy doesn't follow the app's look by itself. When the app's screens change, the demo needs the same change, just as the still picture does today.

The copy follows the real screens as they are now. These details differ from the still picture and from the first storyboard:

- Step one's title is "Install the addon", then "Addon installed".
- The setup window has the still `Fog` in its header, the steps' full texts, and a footer: "Add a game folder…" and "Free · works offline".
- Character rows end in a "›" arrow.
- There is no "New" badge on a new character.

One difference from the app is Jordan's choice (2026-10-20): text meant to be read, which the app draws in its faint grey (the line under each character, the folder card's path, the note under the install button, and "Free · works offline"), uses the brighter muted grey on the site, as the still picture did. Deliberately dimmed parts, such as the waiting step numbers and the row arrows, stay faint.

## The story

The window is the app's real size, 400 × 640. Times are from the start of the loop and only rough: the builder tunes them by eye, but keeps the order and keeps every change moving. "Glides" means the pretend cursor moves to a target in about 0.6 s on an eased curve. "Clicks" means the target darkens and shrinks slightly for about 120 ms, with a soft ring spreading out from the cursor.

### Part one: setup (about 0 to 8.5 s)

| At | What happens |
|---|---|
| 0.0 | The window is closed and the menu bar icon unlit. The setup lines fade in beside it. |
| 0.4 | The cursor glides to the compass in the menu bar and clicks. The icon lights. |
| 1.0 | The window drops open under the icon: it fades in, growing slightly from the icon down. It shows the setup screen, "Set up Road to Sixty". Step 1 is current: **Install the addon**, with a folder card ("Classic", "/Applications/World of Warcraft", "No addon yet"), the cream "Install Road to Sixty 1.10.2" button and its note. Steps 2 and 3 are dimmed, showing only their texts. |
| 2.0 | The cursor glides to Install and clicks. |
| 2.8 | The card's "No addon yet" fades to "Addon 1.10.2". The button and its note fold away smoothly. Step 1's number pops into a blue tick (it grows a little past full size and settles), and the title fades from "Install the addon" to "Addon installed". |
| 3.8 | Step 2 becomes current: its number ring and title brighten, and "This PC's name", the name box and the cream "Link this PC" button open out below its text. The box gets the blue focus border, and "Desk" types into it a letter at a time with a blinking caret. |
| 5.2 | The cursor glides to "Link this PC" and clicks. |
| 6.0 | The name box and button fold away. Step 2's tick pops in, and "Linked to Player#0000." fades in under its text. |
| 6.6 | Step 3 becomes current, **Restart WoW once**: its ring and title brighten and the cream Done button opens out. |
| 7.4 | The cursor glides to Done and clicks. |
| 8.0 | The setup screen slides out to the left as the Characters screen slides in from the right. |

### Part two: the app at work (about 8.5 to 24 s)

| At | What happens |
|---|---|
| 8.5 | The Characters screen: compass, "Road to Sixty", "Player#0000", the Characters and Account tabs, and an empty list. The status pill says "Syncing…" with its dot spinning as a ring. The "characters arrive" lines fade in. The cursor fades away and doesn't come back this loop. |
| 9.2 | Thalrok rises into the list ("Level 42 Warrior", "9d 4h", "Classic PvE · Desk, just now"). Mirelle follows about 0.5 s later ("Level 27 Hunter", "3d 11h", "Classic PvE · Laptop, yesterday"), then Brannoc ("Level 60 Paladin", "18d 2h", "Classic PvE · Laptop, yesterday"). |
| 11.0 | The pill fades to "Synced just now", and its dot gives one soft pulse. |
| 12.5 | The "level up" lines fade in. The menu bar clock rolls from "Tue 21:44" to "Tue 23:12", as if a session went by. The pill goes back to "Syncing…". |
| 13.3 | Thalrok's level rolls from 42 to 43 like a counter, his played time ticks from "9d 4h" to "9d 6h", and his row's border glows blue and fades over about 1.2 s. |
| 14.3 | The pill fades back to "Synced just now", with a pulse. |
| 16.0 | The "new character" lines fade in. The clock rolls to "Wed 19:30". The pill says "Syncing…". |
| 16.6 | Ysolde arrives at the top of the list ("Level 1 Mage", "12m", "Classic PvE · Desk, just now"). The rows below slide down smoothly to make room as she rises in with the same glow. Thalrok's line fades to "Classic PvE · Desk, 20 h ago", since his session ended at 23:12 the day before. |
| 17.6 | The pill fades to "Synced just now", with a pulse. |
| 18 to 22 | It holds on the full list. |
| 22.0 | The window closes, the reverse of opening, and the menu bar icon goes unlit. |
| 23.0 | The loop starts again. |

### The lines beside the window

Each part swaps both lines at once with a fade, when the window enters that part. Each line is a small heading with no full stop, then the text under it. The wording is Jordan's choice, except where noted.

| Part | Left | Right |
|---|---|---|
| Setup | **Three clicks, once**<br>It finds WoW, puts the addon in, and links this PC to your Battle.net account. | **In your menu bar or tray**<br>It opens under its icon and stays out of the way. Close the window and it keeps syncing. |
| Characters arrive | **Every character, every PC**<br>The ones you played on the laptop come down to this PC too. | **Nothing to copy by hand**<br>It reads the addon's saved journeys itself. |
| Level up | **Backed up after every session**<br>When you log out, it sends the journey up. | **Ready before you log in**<br>When the game starts, it brings the newest one back. |
| New character | **New characters join by themselves**<br>Make one, play, log out, and it's on the list. | **Free, with nothing to buy**<br>No subscription, no ads, no paid version. |

The last right-hand line is my call. Jordan first agreed to "Free, and it works offline", but the website design rules out an offline claim, since WoW is an online game.

## The still picture

Anyone who asks their system for reduced motion, or who has scripts off, sees today's still picture: the lit icon, the Characters screen with today's four characters (Ysolde at level 12) and "Synced 2 min ago", and today's two lines ("In your menu bar or tray", "Backed up after every session"), with their full current text. This is also what the page's HTML shows before the island loads. It is not a fallback to tidy up later; it has to look as finished as it does now.

When the island starts, the first loop begins at 1.2 s, just after the window has opened: the still Characters screen slides away as the setup screen slides in, the same move as the screen change at 8.0 s. Starting at 0 instead would close the window and leave the section empty for about two seconds just as it comes into view (seen on 2026-10-21). Later loops start at 0 and keep the close and reopen.

## How it is built

- **One island.** `AppPicture.astro` renders the demo component with `client:visible` and a root margin of `-35% 0px`, so React is downloaded only once the demo has come about a third of the screen's height up from the bottom, not with the page. The demo sits about 560 px down the page, so a screen taller than about 860 px still loads it at once, which is right, since the demo is already in view there. A percentage rather than pixels, so a short landscape phone still loads it once scrolled to. Astro already has `@astrojs/react`. Nothing else on the page changes.
- **The section's rise-in.** An Astro island is wrapped in an `astro-island` element that takes up no box of its own, which can't fade, so the island sits inside one ordinary element that can (see the `display: contents` rule in `apps/web/AGENTS.md`). That means the section now rises as one block, not its three columns one after another as before.
- **The story is plain data.** A plain TypeScript file holds the words and a function of time that builds what is on screen at second t from a run of `if (t >= …)` steps, with tests (the order, the total length, and that every part has both its lines), as `countdown.ts` is. The component only plays it.
- **Only while seen.** The loop starts once half the demo is on screen, or half the screen's height on a screen too short for that (landscape phones). It pauses when the section leaves the screen or the tab is hidden, and carries on from where it stopped.
- **No pause button (Jordan, 2026-10-21).** One was built for WCAG 2.2.2, which asks for a way to stop anything that moves by itself for more than 5 seconds, and Jordan had it taken out before shipping. Visitors who ask for reduced motion get the still picture, and the loop stops whenever the demo is off screen.
- **No jumping.** The window is 640 tall at every width, and the still picture is exactly the same size, so nothing moves when the island takes over. Each side's lines keep the height of their longest version, so nothing moves as the demo plays.
- **Phones (my call).** The menu bar strip is hidden as now, so the loop skips the icon click, and the window simply fades in and out. The window keeps the full 640 height and fills the width up to 400 px, with its text wrapping. The still picture on phones is the same size, with all four rows and the footer, so the island can take over without a jump. Both pairs of lines stay below the window, left then right, as now, each in a slot as tall as its longest version.
- **The clock at the loop's end (my call).** While the window is closed, the clock fades out and back in at "Tue 21:44", rather than rolling backwards.
- **Screen readers** get a short fixed label for the window (it is `role="img"`, as now: "The Road to Sixty app, shown as a short looping demo of setting it up and syncing characters.") and all four pairs of lines once, as one plain list, not text that keeps changing.
- **The cursor** is raster art, not a drawn SVG. It is the game's own gauntlet pointer, which Jordan picked over an ordinary arrow from screenshots (2026-10-20).

## Rules to update in the same commit

- `apps/web/AGENTS.md`: the app demo is the one island that sends React to the browser; everything else stays rendered at build time with CSS animation. Add the demo's files to the Layout list.
- `2026-10-15-website-design.md`: item 3 of the home page and "Shared components" point here.

## Testing

- `bun test` for the story data.
- `bun run typecheck` and `bun run build` in `apps/web`.
- Screenshots at 1280 px and 390 px, with motion (several moments through the loop) and with reduced motion, compared with the real app's screens before merging.
- The page's size with and without the island, so the cost of React is known.

## Left out

- The browser sign-in and the link code.
- The Account tab, History and any clicks on a character.
- Anything that reacts to the visitor's mouse, including a pause button. It's a film, not a toy.
