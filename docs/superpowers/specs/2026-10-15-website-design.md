# Website: design

The public site for Road to Sixty (#1): it says what the addon and the app do, offers the app's download for the visitor's computer, and holds the Privacy and Terms pages. It replaces the spec's "The website" section (`2026-10-12-sync-and-backup-design.md`) where the two differ.

Mockups: the "Website" row of the mockups canvas (https://claude.ai/artifact/M1btBtHDuiExpSuHU7Pg8Z): `Site-Home` (the top of the page), `Site-Below-2` (the rest of it, picked), `Site-Phone` (phone width) and `Site-Privacy`. `Site-Below-1` was not picked.

## What it is for

A player who has heard of the addon lands here, understands in a few seconds that the app keeps their journey safe and the same on every PC, and downloads the right file for their computer. Nothing on the site needs an account: signing in and every account screen live in the app (Jordan, 2026-10-14).

Success: the page loads fast with almost no JavaScript, the main button offers the right download, a Mac or Windows player gets past the unsigned-app warning on their first try, and the Privacy page says plainly what is kept and how to have it removed.

## Decisions (Jordan, 2026-10-15)

- **Astro, not Next.js.** The site is static pages; none of Next.js's server features are needed.
- **Hosted on Vercel**, as the earlier spec said: static files, a preview for every branch.
- **Run by Jordan Burch**, linked to https://jordanburch.dev. The contact for privacy requests is Jordan's email, which comes from a build setting so it stays out of the repo (the repo may go public). The site itself shows it.
- **The lower page is option 2, "show the road"**, with Jordan's edit: no install-steps section on the home page.
- **The unsigned-app steps move to a download page.** The Download button starts the download and opens a small page with only that computer's steps.
- **No "works offline" claim.** WoW is an online game, so it means nothing to a player.
- **The journey map screenshots crossfade:** the three Jordan took (2026-10-15).

## Pages

### Home (`/`)

Top to bottom, as in `Site-Home` and `Site-Below-2`:

1. **Header:** compass and "Road to Sixty", then How it works (an anchor to the merge band), Privacy, Terms and a cream Download button.
2. **Hero, over the moving fog:**
   - the badge "The companion app for the Road to Sixty addon"
   - "Your road to sixty, on every PC you play."
   - the line under it
   - the Download button for the visitor's computer, and "Get the addon"
   - a small line naming the other platform, with its link
   - The fog is the shared `Fog` with two roads and a 22 s loop. It is still for anyone who asks their system for reduced motion.
3. **The app:** a menu bar strip with the compass icon lit and the app's window hanging under it, showing the Characters screen with made-up characters and class icons. One line on each side: "In your menu bar or tray" and "Backed up after every session". It is built in HTML from the shared theme, not a screenshot, so it stays sharp and matches the app.
4. **"One road, whichever PC you played on."** A full-width fog band:
   - Desk's road (blue) and Laptop's road (cream) light up and join, then the joined road carries on.
   - Labels: "Monday on Desk · levels 18 to 20", "Tuesday on Laptop · levels 20 to 22", "Joined", "Wednesday, on either PC: the whole road".
   - The loop is 9 s, faster than the hero's.
5. **"Every step from 1 to 60, replayed on the world map."** Jordan's three in-game screenshots crossfade, about 6 s each, with captions that light up in step: "Two continents, levels 1 to 30", "Westfall, level 18", "The Wetlands, level 23". With reduced motion, only the first shows.
6. **Three facts in a row:**
   - Every version kept
   - Works without the app
   - Yours: download it all, or delete it all, nothing public, nothing sold
7. **"Ready for launch day."** WoW Forever launches on 4 November; install the addon now so the road starts at level 1. Both buttons again. This section goes after launch.
8. **Footer:** "Road to Sixty, made by Jordan Burch" (linked), Privacy, Terms, and "Not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc."

At phone width (`Site-Phone`), the same sections stack:
- The main button reads "Download for Mac or Windows", and a line says the app runs on a computer, not a phone.
- The app picture drops the menu bar strip.
- The fog band and screenshots shrink to the screen's width.

### Download (`/download/mac`, `/download/windows`)

Opening the page starts that platform's download. It has a plain link to download again if nothing started, the steps for that computer with a screenshot, and a link to the other platform's page.

- **Mac:**
  1. Open Road-to-Sixty.dmg and drag the app into Applications.
  2. Open it. When macOS says it can't check the app, click Done.
  3. In System Settings, Privacy & Security, click Open Anyway.
  4. Click Open Anyway once more and enter your password.
- **Windows:**
  1. Run Road-to-Sixty-Setup.exe.
  2. When Windows says it protected your PC, click More info.
  3. Click Run anyway. It installs for you only and needs no admin rights.

Then: open the app, name the PC, link it, and restart WoW once.

### Privacy (`/privacy`) and Terms (`/terms`)

One readable column, as in `Site-Privacy`.

**Privacy** covers, in plain words:
- **The addon alone:** it saves only in the player's own WoW folder.
- **What the app sends:**
  - the BattleTag
  - the Battle.net account number, kept only as a keyed hash
  - each character's name, realm and journey, including the names of other players grouped with
  - each linked PC's name, platform and versions
- **Where it's kept:** a server Jordan runs, and journey files in Cloudflare R2. Database backups age out within 30 days.
- **Who sees it:** only the player, through the app.
- **Deleting it:** Delete everything in the app, or email. It is gone from backups within 30 days.
- **Cookies:** none on the site. The link page sets one only while linking.
- **Battle.net:** only the account number and BattleTag are received, never a password.
- **Who runs it:** Jordan Burch, with the contact email.

**Terms:**
- Free, provided as is, with no warranty.
- Use it only for your own characters, and don't try to break or overload the service.
- The service may change or end, with notice where possible, and players can always download their data first.
- Not affiliated with Blizzard.
- Contact by email.

### Not found (`404`)

The header, "This page doesn't exist", and a link home.

## How it is built

- `apps/web` is Astro with static output, Tailwind 4 and `packages/ui`'s theme, matching the app's window.
- **Shared components:** Astro renders the shared React components (`Fog`, `Button`) to HTML at build time, with no React sent to the browser. Every animation is CSS.
- **The one script** reads the browser's platform (`navigator.userAgentData` where present, else the user agent) and sets the main Download button and the "also for" line. Without the script, the page shows both downloads. The rule that picks the platform is a plain function with tests.
- **The fog band needs roads in their own colours,** timed one after another. `packages/ui/src/dots.ts` gains that: each lit dot knows which road it belongs to and when in the loop it lights. The hero, the link page and the app keep working as they do.
- **The class icons move** from `apps/desktop/src/classes/` to `packages/ui`, so the site's app picture and the app share one copy.
- **The screenshots** go in `apps/web/public/journey/` as JPEGs, at 2000 px wide. Only Jordan's own characters may appear in them. Any other player's name must be blurred out first, as for any other public place.
- **Build settings** (Vercel's environment, never code):
  - `PUBLIC_SITE_URL`
  - `PUBLIC_DOWNLOADS`: `https://dl.rts.everhold.online`, so the links are `app/Road-to-Sixty.dmg` and `app/Road-to-Sixty-Setup.exe`
  - `PUBLIC_ADDON_URL`: the addon's CurseForge page
  - `PUBLIC_CONTACT_EMAIL`
- **No tracking:** no analytics, no cookies, no fonts from other sites. Geist comes from the same `@fontsource` package the app uses.

## Hosting

- A Vercel project with its root at `apps/web`, building with Bun.
- `rts.everhold.online` points at it while testing; `roadtosixty.online` at release, as the earlier spec says.
- Jordan creates the project and the DNS record, since both need his accounts, and the build settings go in there.

## Testing

- **The platform rule:** `bun test` covers Mac, Windows, Linux, an iPhone and an Android phone, plus an unknown or missing user agent. The phones and Linux get the both-downloads layout.
- **The coloured roads in `dots.ts`:** tests that each dot knows its road and lights in its road's turn.
- **The build:** `astro check` and `astro build` in CI, beside the other apps.
- **Comparing with the mockups:** screenshots at 1280 px and 390 px, with motion and with reduced motion, before merging.

## Left out

- Linux downloads, until the app builds for Linux.
- Sign-in, account pages and journeys on a map in the browser. Accounts stay in the app.
- Analytics of any kind.

## Open items

- **Liairene:** Jordan confirms whether it is one of his characters. If not, it is blurred in the screenshots.
- **The server's country** for the Privacy page. Without it, the page says "a server Jordan runs".
- **The Windows "protected your PC" screenshot,** from Jordan's Windows PC. The Mac "Open Anyway" one can be taken here.
- **The addon's CurseForge address** for `PUBLIC_ADDON_URL`.
