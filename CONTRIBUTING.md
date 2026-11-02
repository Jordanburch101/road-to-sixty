# Contributing to Road to Sixty

Thanks for wanting to help. Road to Sixty is MIT licensed, and so is anything
you contribute: by opening a pull request you agree your changes are released
under the same licence.

## Before you start

- **Look for the issue first.** Features, bugs and the decisions behind them
  live in [GitHub issues](https://github.com/Jordanburch101/road-to-sixty/issues).
  For anything bigger than a quick fix, open one before you write code, so we
  can agree on the shape of it. Issues are public: no secrets, personal
  paths or email addresses.
- **Companion addons.** If you'd rather build an addon that works alongside
  Road to Sixty than change it, see #89, which is where the companion addon
  spec is being designed. Until it lands, keep your addon's data in its own
  saved variables and only read `RoadToSixtyCharDB`.

## Making a change

1. Fork the repo and branch from `main`.
2. Read the `AGENTS.md` in the app or package you're changing. It lists the
   layout, the commands and the rules that bite there. The root `CLAUDE.md`
   has the facts about the WoW Forever client that we've verified in game.
3. Run the tests: `bun install` once, then `bun run test` from the repo root
   (the addon's tests need [LuaJIT](https://luajit.org/); the server's need
   Docker). From `apps/addon`, `./check.ps1` runs what CI runs, if you have
   PowerShell.
4. Open a pull request against `main`. CI runs on it. Reference the issue in
   your commits (`Guilds: record joining (#5)`), with subjects of the form
   `Area: what changed`.

Every pull request is reviewed and tested in game by the maintainer before it
merges. The server and website deploy from `main`, so expect a slower merge
for anything that touches them.

## Rules that bite in the addon

- Files load in toc order and share the addon table `ns`.
- `Packed.lua`, `Tidy.lua`, `Parse.lua`, `Tally.lua` and `Merge.lua` make no
  game calls: the sync server runs them under plain Lua 5.1, and
  `tests/pure_test.lua` fails if one does.
- Any change to what is saved, or what it means, bumps `DATA_VERSION` in
  `Core.lua`, gets listed there, and brings older files up in `Upgrade`.
- Saved times use `ns.Now()`, never `time()`.
- Wrap event handlers in `ns.On` so one error can't stop the recorder.
- Real SavedVariables files hold other players' names and GUIDs. They never
  go into a test, a fixture or an issue; the fixtures use made-up names.
- Comments are plain sentences that explain why, in British spelling.

## What to expect

The recorder matters most: journey data lost at launch can't be recreated,
so changes to it get the closest look. Visual changes (icons, line styles,
effects) are easiest to review from a screenshot, so include one.
