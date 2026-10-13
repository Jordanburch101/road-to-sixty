# Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The repo becomes a Turborepo workspace with Bun, the addon in `apps/addon/`, so the server, website and app can be built beside it on `dev`.

**Architecture:** The addon's whole tree (`RoadToSixty/`, `tests/`, `scripts/`, `check.ps1`, `.luarc.json`) moves into `apps/addon/` with `git mv`. Its scripts find the addon relative to their own folder, and its tests by paths relative to where they run, so nearly nothing inside changes as long as they run from `apps/addon/`. A root `package.json` and `turbo.json` add `bun run test`, `check` and `package`. The addon's `test` runs every test under LuaJIT, and again under standard Lua 5.1 when it is installed. CI runs on `dev` too, and installs both.

**Tech Stack:** Bun 1.4.2 (workspaces, package manager, test runner script), Turborepo 2, LuaJIT, PUC Lua 5.1, PowerShell (`check.ps1`, `package.ps1`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "Repo layout", "Testing" (Merge: "Offline tests run under both LuaJIT and standard Lua 5.1, with CI installing both"), "Build order" step 4.

## Global Constraints

- Every part, the addon included, lives under `apps/` (spec). The addon folder keeps the name `RoadToSixty`, because WoW loads an addon only from a folder named like its `.toc` (spec).
- Root keeps `package.json`, `turbo.json`, `bun.lock`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/workflows/`, `docs/`, `branding/` (spec's tree).
- The addon release build still copies only the `RoadToSixty` folder (spec). The release zip and its name don't change.
- The move updates every path that points at `RoadToSixty/` from the repo root: `package.ps1`, `check.ps1`, `.luarc.json`, `ci.yml`, `release.yml`, the tests' `loadfile` calls, the data generator scripts, CLAUDE.md's layout table, and the dev junction on Jordan's Windows PC (spec).
- Releases are tagged on `main` and built by `main`'s workflows, so nothing here changes a release until `dev` is merged into `main`.
- Commit subjects are `Area: what changed (#1)`. Nothing personal (paths, emails) in the repo.

## Decisions the spec leaves open

- **Not waiting for #35.** The spec has the move after #35 ships. Jordan decided (2026-10-13) to do it on `dev` now. `main` keeps the old layout and keeps releasing. An addon fix made on `main` later is merged into `dev` across the move, and git's rename detection carries it over. The spec's line changes to say so.
- **Addon commands run from `apps/addon/`.** That keeps every relative path in the tests and `sync-folder.lua` as it is. CLAUDE.md and README say so.
- **One test command, two runtimes.** `apps/addon/scripts/test.ts` runs `tests/*_test.lua` under `luajit`, then under standard Lua 5.1 if `lua5.1` is on the path or `LUA51` names it. All 21 test files pass under PUC Lua 5.1 today. On a PC without Lua 5.1, it says it skipped that run, so `bun run test` works on the Mac and the Windows PC as they are. CI installs both.
- **`check.ps1` stays as it is.** It does the syntax check, LuaLS and the LuaJIT tests, and runs from wherever it lives. `bun run check` calls it through `pwsh`, so it needs PowerShell, as now.
- **No `tsconfig.base.json` or `packages/` yet.** Nothing uses TypeScript besides one Bun script, which needs no config. The server step adds them with the first TypeScript package.
- **CI runs on pushes to `main` and `dev`**, and on pull requests. The release and CurseForge workflows only change paths. `curseforge-check.yml` can be run on `dev` to prove its paths. `release.yml` is checked by reading it against `ci.yml`, since running it makes a real release.
- **`turbo` caches `test` and `check` but not `package`.** The package version comes from `git describe`, which turbo can't see.

## Review Focus

1. A path that still points at the old root, in a script only CI or a release runs (`package.ps1`, `sync-version.ps1`, `curseforge.sh`, `changelog.sh`, the workflows). Task 1 greps for them. Task 3 proves the CI ones in a real run.
2. `.gitignore` rules that used to be anchored at the root (`RoadToSixty/shots/`) silently stop ignoring. Task 1.
3. The release workflow's zip path and notes path after the move. Task 3 reads them against the CI run's output.
4. `bun run test` on a machine without Lua 5.1 fails instead of skipping. Task 2 runs it here, where `lua5.1` isn't on the path.
5. Windows paths in `test.ts` (backslashes from the glob). Task 2 passes paths to `Bun.spawnSync` without changing them, and runs from the package folder.

---

### Task 1: Move the addon into apps/addon

**Files:**
- Move: `RoadToSixty/`, `tests/`, `scripts/`, `check.ps1`, `.luarc.json` → `apps/addon/`
- Modify: `apps/addon/scripts/changelog.sh`, `branding/make-tga.ps1`, `branding/make-cog.ps1`, `.gitignore`, `README.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

- [ ] **Step 1: Cut the branch and move**

```bash
git switch dev && git switch -c sync-workspace
mkdir -p apps/addon
git mv RoadToSixty tests scripts check.ps1 .luarc.json apps/addon/
git status --short | head -5
```
Expected: rename lines such as `R  RoadToSixty/Core.lua -> apps/addon/RoadToSixty/Core.lua`.

- [ ] **Step 2: Run the tests from the new place**

```bash
cd apps/addon && for t in tests/*_test.lua; do luajit "$t" >/dev/null || echo "FAILED: $t"; done; luajit tests/release_load.lua RoadToSixty; cd ../..
```
Expected: no `FAILED` line, and `Release load test passed: 48 files loaded from RoadToSixty.`

- [ ] **Step 3: Fix the paths that leave the addon's tree**

`apps/addon/scripts/changelog.sh`: change

```bash
file="$(dirname "$0")/../CHANGELOG.md"
```

to

```bash
file="$(dirname "$0")/../../../CHANGELOG.md"
```

`branding/make-tga.ps1`: change `"RoadToSixty/icon.tga"` to `"apps/addon/RoadToSixty/icon.tga"`.

`branding/make-cog.ps1`: change `"RoadToSixty/cog.tga"` to `"apps/addon/RoadToSixty/cog.tga"`.

`.gitignore`: change

```
# Release builds (scripts/package.ps1)
build/
dist/
```

to

```
# Release builds (apps/addon/scripts/package.ps1)
build/
dist/

# Bun and Turborepo
node_modules/
.turbo/
```

and change `RoadToSixty/shots/` to `apps/addon/RoadToSixty/shots/`.

Run: `bash apps/addon/scripts/changelog.sh 1.8.0 | head -3`
Expected: the first lines of the 1.8.0 notes, not "CHANGELOG.md has no notes".

- [ ] **Step 4: Check nothing else points at the old root**

```bash
git grep -n -e 'RoadToSixty/' -e 'scripts/' -e 'check\.ps1' -e 'tests/' -- ':!docs' ':!apps/addon/RoadToSixty' ':!apps/addon/tests' | grep -v '^apps/addon/scripts/.*\.py:[0-9]*:  RoadToSixty/'
```
Expected: only lines in `.github/workflows/` (Task 3 fixes them), `README.md` and `CLAUDE.md` (next step), and `apps/addon/scripts/` lines that are relative to the addon folder (`curseforge.sh`'s `$(dirname "$0")/../RoadToSixty`, `sync-folder.lua`'s `RoadToSixty/...` loads, `package.ps1`'s `tests/release_load.lua`, `check.ps1`'s `tests`). Check each one by reading it.

- [ ] **Step 5: Docs**

`CLAUDE.md`:

- Change the layout table's opening sentence ``RoadToSixty/` is the addon; files load in toc order and share the addon`` to ``apps/addon/RoadToSixty/` is the addon (the repo is a Bun and Turborepo workspace; every part lives under `apps/`); files load in toc order and share the addon``.
- In "## Commands", change the code block's opening fence to start with:

```powershell
# From the repo root
bun install                         # once, for turbo
bun run test                        # every addon test under LuaJIT, and under Lua 5.1 if installed
bun run check                       # check.ps1 through turbo (needs PowerShell)

# From apps/addon
```

  and keep the six existing command lines below it unchanged.
- Change `Run `check.ps1` from the repo root.` to `Run the addon commands from `apps/addon/`.`
- In "## Release", change `` `bash scripts/changelog.sh X.Y.Z` `` to `` `bash apps/addon/scripts/changelog.sh X.Y.Z` `` and `Run `check.ps1` and `scripts/package.ps1`` to `Run `check.ps1` and `scripts/package.ps1` in `apps/addon/``.
- In "## Testing in game", change ``to this repo's `RoadToSixty/` `` to ``to this repo's `apps/addon/RoadToSixty/` ``.

`README.md`:

- Change ``The addon folder is `RoadToSixty/`, `` to ``The addon folder is `apps/addon/RoadToSixty/`, ``.
- Under "## Development", after the LuaJIT sentence, add: `The repo is a Bun and Turborepo workspace: `bun install`, then `bun run test` at the root runs every addon test. The addon's own commands below run from `apps/addon/`.`
- Change ``link or copy `RoadToSixty/` into`` to ``link or copy `apps/addon/RoadToSixty/` into``.
- Change ``This writes `build/RoadToSixty/` and `dist/RoadToSixty-<version>.zip`, `` to ``This writes `apps/addon/build/RoadToSixty/` and `apps/addon/dist/RoadToSixty-<version>.zip`, ``.
- Change ``rerun `python scripts/zone-overlays.py <build>` `` to ``rerun `python apps/addon/scripts/zone-overlays.py <build>` ``.
- Change ``./scripts/sync-version.ps1    # sets`` to ``./apps/addon/scripts/sync-version.ps1    # sets``.
- In "### CI", change ``every push to `main` and every pull`` to ``every push to `main` or `dev` and every pull``.

Spec, "Repo layout": change ``The addon moves into `apps/addon/` as the first commit of the workspace step, after #35 has shipped.`` to ``The addon moves into `apps/addon/` as the first commit of the workspace step, on `dev` (decided 2026-10-13: `main` keeps the old layout and keeps releasing, and fixes on `main` are merged into `dev` across the move).``

- [ ] **Step 6: Commit**

```bash
git add -A apps/addon branding .gitignore README.md CLAUDE.md docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git status --short | grep -v '^R ' | head
git commit -m "Workspace: move the addon into apps/addon (#1)

The addon, its tests, scripts, check.ps1 and .luarc.json move together,
so their relative paths still hold when run from apps/addon. Only the
changelog script, the branding scripts, .gitignore and the docs point
across the move.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git show --stat HEAD | tail -3
```
Expected: the `grep -v '^R '` shows only the modified files listed above, and the commit lists the renames.

---

### Task 2: Bun and Turborepo

**Files:**
- Create: `package.json`, `turbo.json`, `bun.lock` (by `bun install`), `apps/addon/package.json`, `apps/addon/scripts/test.ts`

**Interfaces:**
- Produces: root `bun run test`, `bun run check`, `bun run package`; `apps/addon` tasks `test`, `check`, `package`.

- [ ] **Step 1: The test runner**

Create `apps/addon/scripts/test.ts`:

```ts
// Runs every offline test (tests/*_test.lua) under LuaJIT, then again under
// standard Lua 5.1 when it is installed: lua5.1 on the path, or the
// interpreter LUA51 names. The sync server runs the shared files under
// Lua 5.1, so CI installs both. Run from apps/addon: bun scripts/test.ts

const root = `${import.meta.dir}/..`;
const tests = [...new Bun.Glob("tests/*_test.lua").scanSync({ cwd: root })].sort();
const lua51 = process.env.LUA51 ?? Bun.which("lua5.1");
const runtimes = ["luajit", ...(lua51 ? [lua51] : [])];

let failed = 0;
for (const lua of runtimes) {
  for (const test of tests) {
    const run = Bun.spawnSync([lua, test], { cwd: root, stdout: "pipe", stderr: "pipe" });
    if (run.exitCode !== 0) {
      failed++;
      console.log(`FAILED under ${lua}: ${test}\n${run.stdout}${run.stderr}`);
    }
  }
  console.log(`${lua}: ${tests.length} test files`);
}
if (!lua51) console.log("lua5.1 not found: the standard Lua 5.1 run was skipped");
process.exit(failed > 0 ? 1 : 0);
```

Run: `cd apps/addon && bun scripts/test.ts; echo "exit $?"; LUA51=<the scratchpad's lua-5.1.5/src/lua> bun scripts/test.ts; echo "exit $?"; cd ../..`
Expected: the first prints `luajit: 21 test files`, the skip line and `exit 0`; the second prints both runtimes with 21 test files each and `exit 0`.

Then break one test on purpose (`sed -i '' 's/check(J(5, 7) == 7/check(J(5, 7) == 8/' apps/addon/tests/merge_test.lua`), run `cd apps/addon && bun scripts/test.ts; echo "exit $?"; cd ../..`, expect `FAILED under luajit: tests/merge_test.lua` and `exit 1`, then `git checkout apps/addon/tests/merge_test.lua`.

- [ ] **Step 2: The workspace files**

Create `apps/addon/package.json`:

```json
{
  "name": "@road-to-sixty/addon",
  "private": true,
  "scripts": {
    "test": "bun scripts/test.ts",
    "check": "pwsh -NoProfile -File check.ps1",
    "package": "pwsh -NoProfile -File scripts/package.ps1"
  }
}
```

Create `package.json`:

```json
{
  "name": "road-to-sixty",
  "private": true,
  "packageManager": "bun@1.4.2",
  "workspaces": ["apps/*"],
  "scripts": {
    "test": "turbo run test",
    "check": "turbo run check",
    "package": "turbo run package"
  }
}
```

Create `turbo.json`:

```json
{
  "$schema": "https://turborepo.com/schema.json",
  "tasks": {
    "test": {},
    "check": {},
    "package": { "cache": false, "outputs": ["build/**", "dist/**"] }
  }
}
```

Run: `bun add -d turbo@^2 && bun install`
Expected: `bun.lock` and `node_modules/` appear, and `package.json` gains `"devDependencies": { "turbo": "^2.x.x" }`.

- [ ] **Step 3: Run through turbo**

Run: `bun run test`
Expected: turbo runs `@road-to-sixty/addon#test`, which prints `luajit: 21 test files` and exits 0. Run it again: turbo reports a cache hit (`FULL TURBO` or `cache hit, replaying logs`).

Run: `git status --short`
Expected: only the new files (`package.json`, `turbo.json`, `bun.lock`, `apps/addon/package.json`, `apps/addon/scripts/test.ts`); `node_modules/` and `.turbo/` are ignored.

- [ ] **Step 4: Commit**

```bash
git add package.json turbo.json bun.lock apps/addon/package.json apps/addon/scripts/test.ts
git commit -m "Workspace: Bun and Turborepo, with the addon's tests under LuaJIT and Lua 5.1 (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: CI, release and CurseForge workflows

**Files:**
- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/curseforge-check.yml`

- [ ] **Step 1: ci.yml**

Replace `.github/workflows/ci.yml` with:

```yaml
# On every push to main or dev and every pull request: checks, the addon's
# tests under LuaJIT and standard Lua 5.1, and a release build, uploaded as
# an artifact you can download and install to try.
name: CI

on:
  push:
    branches: [main, dev]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # tags, for the version from git describe

      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: 1.4.2

      - name: Install LuaJIT and Lua 5.1
        run: sudo apt-get update && sudo apt-get install -y luajit lua5.1

      - name: Install
        run: bun install --frozen-lockfile

      - name: Checks
        run: bun run check

      - name: Tests under LuaJIT and Lua 5.1
        run: bun run test

      - name: Release build
        id: package
        shell: pwsh
        working-directory: apps/addon
        run: ./scripts/package.ps1

      # The artifact is zipped by GitHub, so upload the folder: the download
      # then holds RoadToSixty/ ready to drop into Interface/AddOns.
      - uses: actions/upload-artifact@v4
        with:
          name: RoadToSixty-${{ steps.package.outputs.version }}
          path: apps/addon/build/
```

- [ ] **Step 2: release.yml**

In `.github/workflows/release.yml`:

- In the header comment, change `CHANGELOG.md (scripts/changelog.sh)` to `CHANGELOG.md (apps/addon/scripts/changelog.sh)` and `scripts/sync-version.ps1` to `apps/addon/scripts/sync-version.ps1`.
- Change `run: bash scripts/changelog.sh "$GITHUB_REF_NAME" > "$RUNNER_TEMP/notes.md"` to `run: bash apps/addon/scripts/changelog.sh "$GITHUB_REF_NAME" > "$RUNNER_TEMP/notes.md"`.
- Under `- name: Checks and tests`, add `working-directory: apps/addon` after `shell: pwsh`.
- Under `- name: Release build`, add `working-directory: apps/addon` after `shell: pwsh`.
- Change `bash scripts/curseforge.sh upload` to `bash apps/addon/scripts/curseforge.sh upload`.

The zip path comes from `package.ps1`'s `zip=` output, a full path, so the GitHub release and CurseForge steps need nothing else.

- [ ] **Step 3: curseforge-check.yml**

In `.github/workflows/curseforge-check.yml`:

- Change `run: bash scripts/curseforge.sh check` to `run: bash apps/addon/scripts/curseforge.sh check`.
- Change `bash scripts/curseforge.sh upload "dist/RoadToSixty-$version.zip"` to `bash apps/addon/scripts/curseforge.sh upload "dist/RoadToSixty-$version.zip"`.
- Change `"$(bash scripts/changelog.sh "$TAG")"` to `"$(bash apps/addon/scripts/changelog.sh "$TAG")"`.

(`gh release download ... --dir dist` writes to the root's `dist/`, which the upload line reads, so that pair stays as it is.)

- [ ] **Step 4: Nothing left at the old paths**

Run: `git grep -n -e 'scripts/' -e 'check\.ps1' -e 'build/' .github/workflows`
Expected: every match is `apps/addon/...`, a `working-directory: apps/addon` step, or `./check.ps1` / `./scripts/package.ps1` inside such a step.

- [ ] **Step 5: Commit, push dev, and watch CI**

```bash
git add .github/workflows
git commit -m "CI: build the workspace, and run the addon's tests under LuaJIT and Lua 5.1 (#1)

CI runs on dev as well as main. The release and CurseForge workflows
only follow the addon to apps/addon.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The run needs the branch on GitHub. Merge into `dev` locally (`git switch dev && git merge --no-ff sync-workspace`), push `dev`, then:

```bash
gh run list --branch dev --workflow CI --limit 1
gh run watch <id> --exit-status
```
Expected: every step passes, the test step prints `luajit: 21 test files` and `lua5.1: 21 test files`, and the artifact `RoadToSixty-<version>` is uploaded. Then run `gh workflow run curseforge-check.yml --ref dev` and watch it. Expected: the check step passes, or, if the CurseForge token isn't set, it fails only on the token and not on a missing file.

If CI fails, fix it on `dev` with a commit whose subject starts `CI:` and run it again.

---

## Notes for later steps

- **The PC's junction** must point at `apps/addon/RoadToSixty/` after pulling `dev`. Update #38's steps, and tell the PC agent in a comment on #38.
- **`main` and `dev` differ in layout from now on.** Merging `main` into `dev` (for c015749 or any later fix) relies on git's rename detection. Check `git merge` reports no conflict in files it should have followed.
- **The server step** adds `apps/server`, `packages/api` and `tsconfig.base.json`, and extends CI (Bun tests, Postgres service if needed). `turbo.json`'s tasks are where its `build` and `dev` tasks go.
- **`release.yml`** runs for real only from a tag on `main` after `dev` is merged in. Before the first such release, read it once more against a green CI run on `main`.
