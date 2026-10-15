# One journey per character, removing characters, and beta characters

Issue #51. Before launch (2026-11-04).

## Why

A journey is known only by its game folder, realm and name. That breaks
in three ways, and a fourth gap sits beside them:

1. **A namesake joins the old journey.** A character deleted in game and
   made again with the same name uploads under the same name, so the
   server merges the new level 1 into the old journey. WoW probably keeps
   the old character's saved file too, so the addon itself may load the
   old journey for the new character.
2. **Erase doesn't stick.** The addon's Erase (Options) wipes the journey,
   but the next merge joins it with the server's copy, which comes back at
   the next login.
3. **No way to remove one character.** The server deletes only a whole
   account (`DELETE /v1/account`); the app offers only "Delete everything".
4. **Beta characters stay after launch.** Characters from `_classic_beta_`
   stay on the server, listed as "Only on your other PCs so far" and
   counting toward the 100.

Success: a remade namesake or an erased journey starts a journey of its
own, and the old one stays on the server as an earlier journey the player
can remove. Any character can be removed from the backup. Beta characters
are marked "Beta" in the app, with one button to remove them all.
Decided with Jordan: beta journeys stay until the player removes them.

## The journey stamp

Each character file holds `journeyId`, a string `<GUID>:<start>`: the
character's `UnitGUID("player")` and the `ns.Now()` the journey began, such
as `Player-4395-0A1B2C3D:1760500000`. It is a top-level field of
`RoadToSixtyCharDB`, so the app can read it the way it reads `rosterKey`.

### In the addon

At `PLAYER_LOGIN`, in Core.lua, before Sync.lua's handler:

- No `journeyId` (a file from before this change): it takes the logged-in
  character's GUID and the time of its first event (or now if it has
  none). An old file is assumed to belong to the character that logs in.
  The first event, not the login time, so two PCs holding the same merged
  journey give it the same stamp.
- `journeyId`'s GUID differs from `UnitGUID("player")`: the file belongs
  to a deleted namesake. The journey starts fresh, as Erase does, with a
  new stamp. The old journey isn't lost: it is on the server if it was
  ever synced.
- Erase (`ns.ResetCharacter`) gives a new stamp with the same GUID.

`DATA_VERSION` goes from 3 to 4; `Upgrade` sets nothing (the login sets
the stamp, since `UnitGUID` isn't known while upgrading). The Erase
popup's words gain: "Your backup keeps the old journey as an earlier one;
remove it in the Road to Sixty app."

### Bringing in a synced journey

`Sync.Apply` reads the incoming journey's `journeyId`:

- Same stamp as this file: as today (merge, or replace for a restore).
- Same GUID, later start: the journey was erased on another PC. It
  replaces this copy.
- No stamp (sent by a server holding only an old file): as today.
- Anything else (another GUID, or an earlier start of the same GUID): it
  isn't this journey. Left alone, reported as "same" so nothing prints.

`Merge.Merge` refuses two journeys whose stamps both exist and differ
("these are two different journeys"), so no path can join them. When only
one has a stamp, the merged journey keeps it.

## The server

### Characters

`characters` gains `journey` (text, null for rows made before this change)
and `journey_start` (bigint, the `<start>` part, null with it). The unique
key becomes (user, game, realm, name, journey). Migration 0009.

An upload carries the stamp as a new query field `journey`, held to the
same 64 characters as the other fields (a stamp is about 32). The upload finds its row:

1. A row with the same game, realm, name and journey.
2. Else, a row for that name with `journey` null: it adopts the stamp.
   Today's characters move over this way without splitting.
3. Else, a new row (the 100-character cap applies, as today).

An upload with no `journey` (app 0.1.6 and older) goes to the name's
current row, or a new one with no stamp, as today.

The **current** journey of a name is its row with the latest
`journey_start` (a null start counts as earliest; ties go to the higher
id). `/v1/check` lists only current journeys, so a PC is only ever handed
the one journey it should have, and older apps see no duplicate names.
`CheckEntry` gains `journey: string | null`.

`/v1/characters` lists every row and gains `journey: string | null` and
`earlier: boolean` (a row that isn't its name's current journey). The
app's character list matches its rows to current journeys only.

### Removing a character

`DELETE /v1/characters/:id` removes one character of the account: its
jobs, version parents, versions and the row, in one transaction, then its
files, each only when no other version of the account has the same
fingerprint (as the clean-up decides). 404 for a character that isn't the
account's. Counted in `accountRequests`; the 100-cap frees at once.

A removed character that is played again comes back: the app's next upload
of a changed file makes a new row with the whole journey. Removing one that
is still played therefore resets its backup, which the app says.

### A limit

A character deleted and remade before addon 1.10.0 reaches both its PCs
can't be told apart: its old file has no GUID, so the new character
adopts it. Nothing can recover that; from 1.10.0 on it can't happen.

## The app

- The upload sends `journey` from the file's `journeyId` (`sync.rs`, read
  like `roster_key`).
- **Beta.** A character whose `game` is `_classic_beta_` shows a small
  "Beta" tag. Beta characters are listed after the others under a "Beta"
  heading, with "Remove all beta characters" and a confirmation naming how
  many. It removes them one by one.
- **Remove one.** A character's History screen gains "Remove from backup",
  with a confirmation: "Removes [Name]'s journey from the backup. Journeys
  on your PCs stay. If you play [Name] again, its journey is backed up
  again from that PC."
- **Earlier journeys.** A character's History screen lists its earlier
  journeys (level, last played), each with "Remove".
- Version 0.1.7.

## The website

Privacy, "Deleting your data": add that one character, an earlier journey
or every beta character can be removed in the app.

## Testing

- Addon (offline tests): a file without a stamp takes one from the first
  event; a different GUID starts fresh with a new stamp; Erase keeps the
  GUID with a later start; `Sync.Apply` merges the same stamp, replaces a
  later start of the same GUID, leaves another GUID alone; `Merge.Merge`
  refuses two stamps.
- Server: adoption of a null row; a new stamp under a known name makes a
  second row and becomes current; check lists only current journeys;
  `/v1/characters` marks earlier ones; an upload without `journey` goes to
  the current row; `DELETE /v1/characters/:id` removes rows and files,
  keeps a file another character shares, answers 404 for another
  account's character, and frees a slot under the cap.
- App: the upload sends `journey`; the window's beta grouping and removal
  (component logic in `format.ts` tests where it is logic).
- In game (#23 launch checklist and the beta): delete a character, make one
  with the same name, log in: the map starts empty; the app lists the old
  journey as earlier.

## Rollout

Server first (accepts uploads with and without `journey`), then addon
1.10.0 and app 0.1.7 in either order: an old app sends no stamp and keeps
working; an old addon writes no stamp, so its uploads adopt nothing and go
to the current row.
