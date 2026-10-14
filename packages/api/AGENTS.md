# API types (packages/api)

The request and response shapes of the sync API and the account API, shared by the server, the
website and the desktop app's window. `src/index.ts` is the whole package,
TypeScript types and a few constants, with no runtime code.

## Rules that bite

- The desktop app's Rust engine mirrors these shapes by hand in
  `apps/desktop/engine/src/api.rs`. A change here changes the server
  (`apps/server/src/sync.ts`) and the engine in the same commit.
- Each field gets a comment saying what it holds, because the Rust mirror
  and the server both read this file to learn it.
- `CheckEntry.replace` stays until no tester runs app 0.1.1: its `api.rs`
  needs the field. Newer apps read `restore`.

`bun run typecheck` from here checks it.
