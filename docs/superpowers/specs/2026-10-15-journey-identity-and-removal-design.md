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
character's `UnitGUID("player")` and when the journey began. An ordinary
journey's start is `0`; only Erase writes a real time (`ns.Now()`). So
every PC that holds a journey writes the same stamp for it, without
working anything out, and the only stamps that differ for one GUID are
erases. Example: `Player-4395-0A1B2C3D:0`. It is a top-level field of
`RoadToSixtyCharDB`, so the server can read it from an uploaded file the
way the app reads `rosterKey`.

### In the addon

At `PLAYER_LOGIN`, in Core.lua, before Sync.lua's handler:

- `UnitGUID("player")` is read under `pcall`. If it fails or isn't a plain
  string (a secret value), the stamp is left as it is and nothing below
  happens; the in-game checks cover it.
- No `journeyId` (a file from before this change): it becomes
  `<GUID>:0`. An old file is assumed to belong to the character that logs
  in.
- `journeyId`'s GUID differs from the character's: the file belongs to a
  deleted namesake. The journey starts fresh with `<GUID>:0`. Here that
  means wiping the saved table and filling in defaults only; the recorder,
  journal and roster then load it as they would any new character. (Erase
  runs `ns.ResetCharacter`, which resets those modules mid-session and
  reloads; at login they haven't started yet.) The old journey isn't lost:
  it is on the server if it was ever synced.
- Erase gives `<same GUID>:<now>`. Both ways to erase (the Options
  button and `/rts reset confirm`) go through `ns.ResetCharacter`, so the
  stamp is written there: the GUID read again, or the old stamp's GUID if
  the read fails.

`DATA_VERSION` goes from 3 to 4, and `Merge.VERSION` with it (a test keeps
them equal); `Upgrade` sets nothing (the login sets the stamp) and
`Merge.Prepare` brings a layout 3 journey up by its number alone. The Erase popup gains: "Your backup keeps the old journey as an
earlier one; remove it in the Road to Sixty app."

### Bringing in a synced journey

`Sync.Apply` reads the incoming journey's `journeyId`:

- Same stamp as this file: as today (merge, or replace for a restore).
- Same GUID, later start: the journey was erased on another PC. It
  replaces this copy.
- No stamp (a server copy made before this change): as today.
- Anything else (another GUID, or an earlier start of the same GUID): it
  isn't this journey. Left alone, reported as "same" so nothing prints.

`Merge.Merge` refuses two journeys whose stamps both exist and differ
("these are two different journeys"). When only one has a stamp, the
merged journey keeps it (`journeyId` merges by `Join`, not from the copy
seen last).

## The server

### Characters

`characters` gains `journey` (text, null for rows made before this
change). The unique key becomes (user, game, realm, name, journey) with
`NULLS NOT DISTINCT`, so a name still has at most one unstamped row.
Migration 0009.

The upload route reads the stamp from the uploaded file itself (it already
unpacks it), with the same pattern the app uses for `rosterKey`: a
top-level `["journeyId"] = "..."`, at most 64 characters, or none; one
that isn't `<letters, digits, hyphens>:<digits>` answers 400. So apps
need no change for it. The upload's version keeps the stamp
(`versions.journey`, in the same migration), for the worker. The upload's
row:

1. A stamped upload goes to the row with that stamp.
2. Else, if the name has an unstamped row, the upload is queued against it
   and the worker decides (below).
3. Else, a new row with the stamp (the 100-character cap applies).

An unstamped upload (addon older than 1.10.0) goes to the name's
unstamped row, else to its oldest row, else to a new unstamped row. It
never goes to a newer journey, so a PC still on an old addon can't bring an
erased journey back into the new one.

**Adopting.** When a stamped upload meets an unstamped head, the worker
checks they are the same journey: they share their first event (same kind
and time), or the head has no events. The same journey: it merges as
today, and the row takes the stamp. Not the same (a namesake remade before
this change ever reached the server): the worker makes a row for the stamp,
moves the upload and its job there, and the job runs again on that row.
The check lives in `Merge.lua` (`Merge.SameJourney(head, upload)`), and
`runner.lua` runs it in a mode of its own (`same`), so the server uses the
addon's own code. Two uploads with the same stamp can both be queued
against the unstamped row before the worker gets to them: the second
finds the row the first made and moves there. That row is made without
the 100-character cap (at most one per name from before stamps).

The **current** journey of a name is its newest row (highest id). An
Erase or a remade namesake makes a new row; a PC behind on either keeps
updating the older one. `/v1/check` lists only current journeys, so a PC
is only ever handed the journey it should have, and older apps never see a
name twice.

`/v1/characters` lists every row and gains `earlier: boolean` (not its
name's current journey). The app's character list matches its rows to
current journeys only.

### Removing a character

`DELETE /v1/characters/:id` removes one character of the account: its
version parents, versions, queued jobs and the row, in one transaction,
then its files, each only when no other version of the account has the
same fingerprint (as the clean-up decides). 404 for a character that isn't
the account's. 409 "Its latest upload is being merged; try again in a
minute" while one of its jobs is running, since the worker's commit would
otherwise meet a deleted row. The route locks the character's jobs in its
transaction, so the worker can't take one meanwhile. Counted in `accountRequests`; a slot under
the 100 frees at once.

A removed character that is played again comes back: the app's next upload
of a changed file makes a new row with the whole journey. Removing one that
is still played therefore resets its backup, which the app says.

### Limits

- An earlier journey can be removed, not brought back as the current one.
  It can still be downloaded in the export, as `Name (earlier <id>).lua`
  beside the current `Name.lua`.
- A namesake can't be told apart from the old character while the old
  journey has no stamp: a PC still holding the old character's file (that
  file has no GUID, so the new character adopts it at login), or a server
  copy from before 1.10.0 that the sync folder brings in (a journey with no
  stamp merges as today). The shared first event then makes the server
  agree. Every character at launch is new, so this reaches only beta
  characters.

## The app

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
- A 409 from removing shows its text and leaves the character listed.
- The Beta tag comes from the server's `game`. A beta character whose
  saved file is on this PC but that the server no longer has stays in the
  main list: the app's own list doesn't know which game a file is in.
- Version 0.1.7.

## The website

Privacy, "Deleting your data": add that one character, an earlier journey
or every beta character can be removed in the app.

## Testing

- Addon (offline tests): a file without a stamp gets `<GUID>:0`; a
  different GUID starts fresh; Erase keeps the GUID with a later start; a
  GUID read that fails leaves the file alone; `Sync.Apply` merges the same
  stamp, replaces a later start of the same GUID, leaves another GUID
  alone; `Merge.Merge` refuses two stamps and keeps a lone one;
  `Merge.SameJourney` on shared and unshared first events.
- Server: the stamp read from a file (present, missing, too long); a
  stamped upload adopts an unstamped row of the same journey; a remade
  namesake's upload gets a row of its own; a second stamp under a name
  becomes current; check lists only current journeys; `/v1/characters`
  marks earlier ones; an unstamped upload never joins a newer journey;
  `DELETE /v1/characters/:id` removes rows and files, keeps a file another
  character shares, answers 404 for another account's character and 409
  while a job runs, and frees a slot under the cap.
- App: the beta grouping and the removal calls (logic in `format.ts`,
  tested there).
- In game (#23 launch checklist and the beta): `UnitGUID("player")` gives a
  plain string at login, inside an instance too; delete a character, make
  one with the same name, log in: the map starts empty; the app lists the
  old journey as earlier.

## Rollout

Server first (it reads stamps when files carry them and takes unstamped
uploads as today), then addon 1.10.0 the same day, and app 0.1.7 in
either order: the stamp travels inside the file, so any app carries it;
an old addon writes none, so its uploads go to the unstamped or oldest
row. Same day because the server merges at layout 4 from then on: every
PC on addon 1.9.x is told to update the addon and gets no journeys until
it does. A 1.10.0 upload reaching a server still on layout 3 would be
refused as a newer layout, so the server can't go second.
