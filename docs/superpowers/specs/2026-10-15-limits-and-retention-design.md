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
   journey compresses far below that). The upload route also refuses a
   `Content-Length` over 8 MB before reading the body. Both answer 413,
   which the app already shows on the character's row as "Too big to back
   up".
2. **Query strings.** `game`, `realm`, `name` and `addon` longer than 64
   characters are refused with 400.
3. **Upload rate per PC.** At most 30 uploads in any 15 minutes per PC.
   Over that, 429 with `Retry-After`. The app already treats any answer
   other than 413 as "try again next pass", so this needs no app change.
4. **All requests per PC.** At most 600 requests an hour per PC across
   `/v1/*`, to catch an app stuck in a loop. Also 429.
5. **Characters per account.** At most 100. An upload for a 101st new
   character is refused with 422 and the plain-text body "This account
   has reached 100 characters". Existing characters keep uploading.

6. **Uploads per account.** Across all its PCs, at most 60 uploads in any
   15 minutes and 500 in a day, so linking more PCs doesn't multiply what
   one account can send. Also 429.
7. **PCs per account.** At most 20 linked (not unlinked) PCs. Linking a
   21st is refused on the link page with "This account already has 20
   PCs linked. Unlink one in the app first."
8. **Exports.** "Download all my data" builds the whole zip in memory, so
   at most 5 per account an hour. Also 429.
9. **Starting a link without an account.** Better Auth's own limit is on in
   production (100 requests per 10 seconds per address). The endpoint that
   hands the app a link code makes a database row per call, so it gets a
   stricter rule: 10 a minute per address.

The rate limits are counted in memory on the one server process, by PC
id, by account and (for sign-in) by address, with the clock passed in so
tests can move it. A restart forgets them, which is fine for limits this
loose. A key whose window is empty is dropped, so the counts don't grow
with every PC ever seen.

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

### No app change

The app already keeps a 400 or 422 as a refusal on the character's row,
showing the body as the reason ("The server refused it: This account has
reached 100 characters"), and retries anything else but 413. So the limits
need no app release.

## Version clean-up

### The rule

- **Uploads** (the raw file a PC sent): the file is deleted once its merge
  has finished: the version is `accepted`, `rejected` or `superseded` and
  it has no `queued` or `running` job. A `SERVER_FAILED` upload the app
  sends again is stored again, so nothing is lost.
- **Merged and restored versions** (what History shows): every one from the
  last 30 days is kept. Older than that, the newest one in each calendar
  week (Monday to Sunday, UTC) is kept, for good. The rest are deleted.
- **Never deleted:** the character's current version (`head_version_id`);
  the file of any upload with a `queued` or `running` job; and any file
  that a kept version of the same account shares (identical files are
  stored once, at `<user id>/<fingerprint>.zst`).

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
hours, one character at a time:

1. For each calendar week that has ended and holds merged or restored
   versions with none marked `weekly` yet, set `weekly` on the newest
   one. A week still under way is left alone, so the mark always lands on
   the week's last version and each week gets exactly one.
2. Choose the versions to prune: uploads whose merge has finished, and
   merged or restored versions older than 30 days that are neither
   `weekly` nor the head. Leave out any upload with a `queued` or
   `running` job.
3. Delete a chosen version's file only when no other unpruned version of
   that account has the same fingerprint. Delete the file first, then set
   `pruned_at`. If the job stops between the two, the next run deletes
   again; a missing file counts as deleted.

A setting `PRUNE` controls it: `dry` marks each week's kept version (which
deletes nothing) and logs, per character, how many versions, files and
bytes it would prune; `on` prunes; `off` skips the job. The default is
`dry`.

### Other rows

The same daily job deletes merge jobs that finished more than 30 days ago,
and Better Auth's expired link codes, sessions and verifications. Version
rows stay (see above); the upload limits bound how fast they grow.

### History

`GET /v1/characters/:id/versions` returns the newest 100 unpruned merged
or restored versions, then every older `weekly` one, newest first. Pruned
versions never appear, so a restore always has its file.
`GET /v1/versions/:id` answers 404 for a pruned version. The app needs no
change: it lists what it is sent.

### Wording

- Website, the "Earlier versions kept" fact: "Every version from the last
  30 days, then one a week. The newer one stays, so you can switch back."
- Privacy, "Where it's kept": add "Older versions of a journey are thinned
  out: every version from the last 30 days is kept, then one a week."

## Testing

Server tests (Bun, against the Docker Postgres and S3):

- Each limit: a body over 8 MB, a long name, the 31st upload in 15 minutes
  (and the first after the window moves), the 601st request in an hour,
  the 101st character; each with its status, and that the 100th of each
  still works.
- Folding: two queued uploads from one PC fold; a running job, a different
  PC, or a different `received_id` don't.
- Clean-up, with `created_at` moved back by SQL: an upload's file goes once
  merged and not while its job waits; versions inside 30 days stay; one
  per week stays after that; the head stays at any age; a file shared with
  a kept version stays; `dry` deletes nothing; a second run changes
  nothing; a missing file doesn't stop the run; History returns the newest
  100 plus the weekly ones; a pruned version downloads as 404; a stale
  upload still has a pruned restore's stretches stripped.

App: none. `engine/src/sync.rs` already keeps a 400 or 422 as a refusal with the body as its reason.

## Rollout

1. Merge to `dev`; Dokploy deploys with `PRUNE` unset, so `dry`.
2. Read the next day's log of what it would prune for Jordan's characters.
3. Set `PRUNE=on` in Dokploy and redeploy.
4. Comment on #40 and update the website wording in the same merge.
