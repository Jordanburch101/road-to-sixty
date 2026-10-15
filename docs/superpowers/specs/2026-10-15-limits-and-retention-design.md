# Upload limits and version clean-up

Issue #40, item 9, and the retention rule the sync spec planned but never
built. This supersedes the "History and size" paragraph of
`2026-10-12-sync-and-backup-design.md` ("A daily job keeps every version for
30 days and one per week after that...") with the rule and mechanism below.

## Why

The repo is public and roadtosixty.online is live, so anyone can read how
the server takes uploads, and today nothing limits them. One account, by a
bug in the app or on purpose, could fill the one merge worker everyone
shares or keep adding characters and files. Separately, every upload and
every merged version is kept in R2 for good: a full 1 to 60 journey is about
400 KB compressed and the app uploads a few times an hour while playing, so
one character grows to hundreds of megabytes over a playthrough.

Success: a normal player never meets a limit; one account can't hold up
everyone else's merges or grow storage without bound; History still lets a
player go back weeks, not just days.

## Limits

The scarce resource is the merge worker (about 0.7 s per large merge, one
at a time), more than storage. The numbers follow the app's own pace: it
uploads a character at most once every 15 minutes while the game runs,
plus when the game closes and when a file settles, and logging through
several alts can send a burst.

1. **Body size.** `maxRequestBodySize` drops from 33 MB to 8 MB (a 32 MB
   journey compresses far below that); the upload route refuses a read
   body over 8 MB too. Every other request may send at most 16 KB, checked
   before anything reads it (sign-in stores some fields as they come, and
   routes parse a body before checking the PC's token). All 413.
2. **Query strings.** `game`, `realm`, `name` and `addon` longer than 64
   characters are refused with 400.
3. **Uploads per PC.** At most 120 in any 15 minutes: a relink sends every
   character again, up to the 100 an account may have.
4. **Requests per PC.** At most 600 an hour across `/v1/*`.
5. **Characters per account.** At most 100. An upload for a 101st new
   character is refused with 422 and the plain-text body "This account
   has reached 100 characters". Existing characters keep uploading.
6. **Per account, across its PCs:** 240 uploads in 15 minutes, 500 uploads
   and 200 MB of uploads a day, 2,000 requests an hour, 10 new PC links a
   day. Unlinking and relinking gives a PC a new id and a fresh per-PC
   count, so these are what really bound an account.
7. **PCs per account.** At most 20 linked (not unlinked) PCs; the 21st link
   answers 409 with "This account already has 20 PCs linked. Unlink one in
   the app first." One sign-in links one PC, even when asked several times
   at once: the sign-in is used up before the PC is made.
8. **Exports.** At most 5 per account an hour, one at a time on the server,
   and refused (413) when the account's journeys add up to over 512 MB.
9. **Restores.** At most 10 per account an hour, and one at a time on the
   server: each runs the merge program inline.
10. **Starting a link and new players.** Better Auth's own limit is on in
    production (100 requests per 10 seconds per address); the link-code
    endpoint gets 10 a minute per address. At most 200 new players an hour
    across the server, as Battle.net accounts are free.
11. **The merge worker.** It takes the next job from the account it served
    least recently, and a merge that hits its time or memory limit gets one
    more try, not a day of them.

Limits answer 429 with `Retry-After`. They are counted in memory on the one
server process, with the clock passed in so tests can move it; a restart
forgets them, which is fine for limits this loose. Keys whose window has
emptied are swept once per window.

### The visitor's address behind Cloudflare

`api.roadtosixty.online` goes behind Cloudflare's proxy, so floods stop at
Cloudflare. Every request then reaches Dokploy's proxy from a Cloudflare
address. The server takes the address Dokploy's proxy saw (the right end
of `X-Forwarded-For`, as today); when that is one of Cloudflare's
published ranges, it uses `CF-Connecting-IP` instead. A request that goes
around Cloudflare to the server directly can't set the address that way.
Sign-in's limits use this address.

### Folding queued uploads

When a PC uploads a character while its previous upload of that character
is still `pending` with its job `queued` (not yet `running`), and both have
the same `received_id`, the older upload is marked `superseded` and its job
removed: the newer file contains everything the older one did. Different
`received_id`s mean a restore reached the PC in between, so both stay.

This bounds any one account's queue to about one job per character per PC,
which is the fairness the shared worker needs. The worker's order is
unchanged.

### App change (0.1.4)

The app keeps a 400 or 422 as a refusal on the character's row, showing
the body as the reason. Before 0.1.4 any other answer, a 429 included,
stopped the whole sync pass, skipped delivering journeys and showed the
PC as offline. From 0.1.4 a 429 on one upload skips that file until the
next pass and the pass carries on; a 429 anywhere else is worded "the
server is busy" rather than offline, and the server's `{"error": ...}`
bodies are shown as plain text.

## Version clean-up

### The rule

- **Uploads** (the raw file a PC sent): a merged (`accepted`) upload's file
  is deleted once its job has finished. A refused or replaced one
  (`rejected`, `superseded`) is held 30 days first: the app never sends the
  same file twice, so it may be the only copy of that session.
- **Merged and restored versions:** each character keeps its newest 100,
  whatever their age, because that is what History lists. Past those, it
  keeps the ones kept for good: the newest of each finished calendar week
  (Monday to Sunday, UTC), and any version a restore replaced, so the
  player can always switch back. The rest can't be reached and go.
- **Never deleted:** the character's current version (`head_version_id`);
  the file of any upload with a `queued` or `running` job; and any file
  that a kept version of the same account shares (identical files are
  stored once, at `<user id>/<fingerprint>.zst`).

This replaces "every version from the last 30 days, then one a week",
which kept versions History couldn't reach (unbounded for a heavy player)
and deleted ones it could (the newest 100 of a character not played for a
month).

### Rows stay, files go

Pruning deletes the file in R2 and sets a new `versions.pruned_at`; the row
stays. Rows are needed after their files are gone:

- A restore's row holds `removed`, the stretches of play it took out. An
  upload from a PC that was offline for months still has those stretches
  stripped, which needs every restore row since its `received_id`.
- `version_parents` and `jobs` point at version rows.
- An upload's row and fingerprint let the server answer "known" when a PC
  sends the same file again.

A second new column, `versions.weekly` (boolean, default false), marks the
version kept for its week.

### The daily job

It runs in the worker process, a few minutes after start and then every 24
hours, one account at a time (one failing account doesn't stop the rest):

1. For each calendar week that has ended and holds merged or restored
   versions with none marked `weekly` yet, set `weekly` on the newest
   one. A week still under way is left alone, so each week gets one.
2. Choose the versions to prune by the rule above.
3. Set `pruned_at` on them first. A restore locks its source row and
   checks it isn't pruned, so it either finishes before this (and its new
   row, which shares the source's file, counts as kept) or is refused.
4. Delete a chosen version's file only when no unpruned version of that
   account has the same fingerprint. A missing file counts as deleted; a
   crash after marking leaves only stray files, which cost storage.

A setting `PRUNE` controls it: `dry` marks each week's kept version and
logs one line with how many versions, files and bytes it would prune; `on`
prunes; `off` skips the job. The default is `dry`.

### Other rows

The same daily job deletes merge jobs that finished more than 30 days ago,
and Better Auth's expired link codes, sessions and verifications, in a dry
run too, as they aren't journeys. Version rows stay (see above); the
account limits bound how fast they grow. Indexes cover every column a
request, the worker or account deletion reads these tables by.

### History

`GET /v1/characters/:id/versions` returns the newest 100 unpruned merged
or restored versions, then every older `weekly` one, newest first. Pruned
versions never appear, so a restore always has its file.
`GET /v1/versions/:id` answers 404 for a pruned version. The app needs no
change: it lists what it is sent.

### Wording

- Website, the "Earlier versions kept" fact: "Your last 100 versions, then
  one a week. The newer one stays, so you can switch back."
- Privacy, "Where it's kept": "Older versions of a journey are thinned
  out: the last 100 of each character are kept, then one a week."

## Testing

Server tests (Bun, against the Docker Postgres and S3):

- Each limit: refused one past its number, with its status and
  `Retry-After`, and the window moving on; a body over 16 KB refused before
  sign-in reads it; the 101st character and 21st PC; one sign-in linking
  one PC under parallel requests.
- Folding: two queued uploads from one PC fold; a running job, a different
  PC, or a different `received_id` don't.
- The worker: it takes turns between accounts; a limit hit gets one retry.
- Clean-up, with `created_at` moved back by SQL: an upload's file goes once
  merged and not while its job waits; a refused or replaced one is held 30
  days; the newest 100 stay at any age; past them, one per finished week
  and the head stay; a file shared with a kept version stays; versions are
  marked before files go, and a restore whose source is pruned meanwhile is
  refused; the version a restore replaced is kept; `dry` deletes no
  journey; a second run changes nothing; one failing account doesn't stop
  the rest; History returns the newest 100 plus the kept ones and never a
  pruned one; a pruned version downloads as 404; a stale upload still has a
  pruned restore's stretches stripped.

App: a 429 on one upload skips that file and the pass still delivers; a
429 elsewhere reads as busy, not offline.

## Rollout

1. Merge to `dev`, bring `main` up to it, and Jordan pushes `main`: Dokploy
   deploys with `PRUNE` unset, so `dry`.
2. Release app 0.1.4 for the 429 handling.
3. Read the next day's log of what it would prune.
4. Set `PRUNE=on` in Dokploy and redeploy.
5. Comment on #40.
