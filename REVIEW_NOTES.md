# Review notes

## Deliberate choices

1. `ENABLED=0` is the shipped default. It blocks new challenges but pending
   recovery remains active.
2. `flock` replaces the old mkdir lock, so SIGKILL cannot leave a stale lock.
3. The pending transaction is written before `MEDIA` changes and deleted only
   after read-back verification, already-applied detection, external override,
   or a documented unrecoverable missing-old-node case.
4. The current node's dl.google result never prevents a challenge. It is logged
   only; the best valid non-current candidate is tried because dl.google and
   Googlevideo can rank nodes differently.
5. A rate-limited preflight keeps each benchmark connection visible long enough
   to prove its chain contains BENCH and candidate. The formal test is capped at
   12 MiB. A verdict chain must contain MEDIA and new_node. Passive samples count
   only positive deltas that occur after the first snapshot.
6. Infrastructure failures never penalize a node. A sufficient negative verdict
   gives six hours; an inconclusive user/sample verdict gives one-hour retry.
7. A selector change is checked before pending creation, before old-connection
   closure, after observation and at commit/rollback.

## Points to review explicitly

- `YOUTUBE_TARGET_BYTES_PER_SEC=1000000` (about 8 Mbps) is aimed at 1080p with
  margin. Use 2,500,000–3,125,000 for a 20–25 Mbps 4K target.
- `KILL_OLD_CONNECTIONS=1` is necessary for immediate real-path validation, but
  can be set to 0 for the first controlled trial.
- The global post-attempt backoff is 600 seconds, not one hour. Candidate-level
  retry/blacklist periods still prevent loops.
- A KEEP verdict clears pending using the selector verification already made at
  the end of observation; there is no redundant success-path API read that can
  convert a validated winner into a timeout rollback.
- The active-second mean intentionally ignores idle buffer intervals. Both old
  and new use the same definition, but this remains delivered user throughput,
  not a capacity benchmark.
- The implementation is longer than the early 250–350 line estimate because it
  includes API wrappers, durable recovery, detailed JSON logs and race checks.
  Splitting it into files would reduce per-file size but increase deployment
  moving parts; this review build keeps one executable.

## Deployment evidence

- The deployed Mihomo build exposes BENCH and the selected candidate in
  `/connections[].chains` for the `proxy: BENCH` listener.
- `bench-in` accepts unauthenticated loopback requests with `users: []` while
  the global mixed port may retain its own authentication.
- The dl.google endpoint, byte cap, chain verification and candidate download
  run successfully through the dedicated listener.
- Live trials have exercised low-speed detection, candidate selection, pending
  creation, MEDIA switching, old Googlevideo connection closure, 30-second
  validation and successful commit.
- V1.2 additionally lowered champion slow-evidence minima to two active seconds
  and 256 KiB, while leaving the stricter challenger rollback evidence intact.
- V1.3 adds an hourly X activity trigger that reuses the existing Google-network
  throughput benchmark. It requires measured improvement over the current node
  before switching and intentionally does not present that proxy as X truth.
- V1.3.2 gates that trigger on real X download activity: after presence and the
  cheap cooldown checks, it samples `/connections` again over
  `X_ACTIVITY_WINDOW_SECONDS` and requires at least `X_MIN_ACTIVITY_BYTES` from a
  single device. A prior version only checked that X connections existed, so an
  idle background X app could burn the hourly benchmark and two idle devices
  spammed `x_multi_device_deferred` every minute; both now stay silent.
- V1.3.3 applies the activity byte threshold before counting source devices and
  rechecks Googlevideo after X sampling and before pending, preserving YouTube
  priority across the full X preselection interval.
