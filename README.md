# OpenClash YouTube/X/ChatGPT/GitHub MEDIA selector V1.4.1

This directory is the reviewable source of the router deployment.
`config.example` deliberately defaults to `ENABLED=0`; the deployed router
configuration keeps its separately reviewed `ENABLED=1` value.

## Files

- `oc-media-speed-select-v1` — cron entry point and complete state machine.
- `config.example` — documented defaults; all throughput values are bytes/s.
- `oc_media_patch_v1.rb` — idempotently rebuilds MEDIA/BENCH, persists
  `bench-in:7898`, keeps unrelated listeners, and installs
  YouTube/X/ChatGPT/GitHub rules.
- `openclash_custom_overwrite.snippet` — the one line that would be added to
  OpenClash's existing subscription overwrite hook. It reads only the numeric
  listener port from the selector config before invoking the Ruby patcher.
- `tests/check.sh` — non-network syntax and decision tests.
- `tests/sample.yaml` — synthetic config used to test the Ruby patcher.

There is intentionally no installer script. Deployment remains a separate,
explicit and backed-up operation.

## Exact V1.4.1 behavior

Every cron run takes a kernel `flock`. It then handles a durable pending
transaction before looking at `ENABLED`:

```text
OpenClash API unavailable -> leave pending untouched, exit
pending exists            -> recover/finish it, exit
ENABLED != 1              -> exit
no current googlevideo/X  -> exit after one /connections read
                             (X present adds one short activity sampling window)
```

When enabled and real Googlevideo traffic exists:

```text
8-second passive window on chains=[..., MEDIA, current_node]
  -> a >=4 MiB, >=1-active-second burst reaching target proves health immediately
  -> otherwise slow evidence requires one source, >=2 active seconds and >=256 KiB
  -> below target for three valid slow windows within 180 seconds
  -> an insufficient/pause-like window neither increments nor clears that streak
  -> respect 10-minute challenge backoff
  -> trigger preselection
```

The YouTube preselection stage defaults to low-traffic mode. It calls
`/group/BENCH/delay` with the gstatic 204 URL, keeps delays below 800 ms,
excludes penalties, and selects at most three non-current challengers. It does
not run a `dl.google.com` range download for YouTube; real Googlevideo delivery
remains the verdict.

`dl.google.com` active range tests are still used for X-triggered runs, where no
Googlevideo session may exist. The default cap is 1 MiB per node and two seconds.
Each tested node first gets a three-second, 64 KiB/s preflight whose only
purpose is keeping the connection visible for chains verification. Every request
goes through `127.0.0.1:7898`, which is directly bound to BENCH.

Immediately before mutation the script re-reads `ENABLED`, `MEDIA.now`, and
MEDIA membership. It snapshots only old Googlevideo connection IDs matching
MEDIA, old_node, and the triggering source IP, then durably writes:

```json
{
  "version": 1,
  "run_id": "...",
  "old_node": "...",
  "new_node": "...",
  "source_ip": "...",
  "started_at": 0
}
```

After `MEDIA` is switched and read-back verification succeeds, the script
optionally closes those exact old IDs so the player reconnects. It never closes
YouTube account/API, X, or connections discovered after the snapshot.

The 30-second verdict counts only positive byte deltas from connections whose:

- host equals `googlevideo.com` or ends in `.googlevideo.com`;
- chains contain both MEDIA and new_node;
- sole active source IP still equals the triggering device.

Positive and negative evidence are asymmetric. A challenger that downloads at
least 4 MiB in at least one active second may be kept immediately when it
reaches the target or the normal material-improvement formula. A negative
verdict still requires at least four active seconds and 1 MiB, because a pause
must not be treated as evidence that the node is slow.

The challenger is kept when it reaches the configured target, or when both are
true:

```text
new >= old * 1.20
new >= old + 125000 bytes/s   # approximately 1 Mbps
```

For stall-escape challenges, a deliberately lower keep floor also exists: the
challenger may be kept after at least one active second, 512 KiB total delivery,
and 250000 bytes/s. This path is only entered after repeated request/connection
churn with almost no delivery on the old node. If it succeeds, the replaced
stalled champion is blacklisted for 6 hours.

`SELECTOR_AFTER_OBSERVE` is verified before the KEEP calculation. Once KEEP is
decided, pending is cleared without a second API read: a transient control-plane
failure must not turn an already validated winner into a future timeout rollback.

Outcomes:

| Result | Selector action | Candidate scheduling |
|---|---|---|
| target reached or material improvement | keep | none |
| sufficient sample, insufficient improvement | rollback | blacklist 6 hours |
| first user/sample changed or insufficient | rollback | no penalty |
| second such result for the same node within 6 hours | rollback | retry_after 1 hour |
| API/config/infrastructure failure before switch | no change | no penalty |
| API/config/infrastructure failure after switch | rollback/pending recovery | no penalty |

## Pending recovery and external control

`ENABLED=0` prevents new challenges; it does not disable cleanup of an existing
pending transaction. A pending file older than 120 seconds is handled under the
same global lock:

```text
MEDIA.now == new_node  -> rollback if old_node still exists
MEDIA.now == old_node  -> rollback was already applied; clear pending
MEDIA.now == third     -> external/user choice wins; clear pending
old_node missing       -> log rollback_unavailable; clear pending
API/write/verify error -> keep pending for the next cron run
```

The pending file lives under `/etc/openclash/speed-select`, is written via a
same-directory temporary file plus atomic rename, and is followed by `sync`.
The `flock` file itself lives in `/tmp`; kernel locks disappear with the process,
so no stale mkdir lock recovery is required.

If a user changes `ENABLED` while preselection is running, the switch checkpoint
sees it and cancels. If the switch already happened, the active run completes
its verdict or rollback. For manual node selection, first set `ENABLED=0`; a
third-node selection is never overwritten by pending recovery.

## Multi-device and X scope

More than one actively downloading source IP pauses low-window accumulation.
The previous streak is not refreshed and therefore expires after 180 seconds.
If a second device begins during the challenge observation, the result becomes
inconclusive and rolls back.

YouTube remains the primary optimizer and uses real Googlevideo delivery as its
final verdict. X/Twitter traffic is also an activity trigger. X presence alone is
not enough: after a matching connection is seen, the script samples `/connections`
again over a short `X_ACTIVITY_WINDOW_SECONDS` window and requires at least
`X_MIN_ACTIVITY_BYTES` of measured download delivery from a single device, so an
idle background X app neither probes nor emits a multi-device deferral. When that
active-usage check passes without concurrent Googlevideo traffic, at most once
every 15 minutes the script runs the existing current-node plus candidate
`dl.google.com` throughput comparison.
Per-device byte totals are filtered by that minimum before multi-device counting,
so a heartbeat from another idle device cannot defer an active user. Googlevideo
is checked again after the activity window and immediately before writing pending;
if YouTube appeared meanwhile, the X run exits without changing MEDIA.
The current-node benchmark is retried once. A probe that cannot form a valid
comparison backs off for 5 minutes; only a completed comparison consumes the
normal 15-minute cooldown.
It switches MEDIA only when the best candidate is at least 20% and 125000
bytes/s (about 1 Mbps) faster than the current node. This deliberately assumes
that a generally faster Google-network path is a useful proxy for X; it does not
claim to measure X CDN throughput directly.

An X-triggered run uses the same BENCH listener and chain verification, durable
pending transaction, selector read-back and external-user protection. On a
successful switch it closes only the triggering device's pre-switch X,
Twitter and twimg connections so the client reconnects. It does not run the
30-second Googlevideo verdict because no YouTube session may exist. YouTube has
priority whenever both services are active.

## Stall Escape

The stall probe covers the champion-side "too dead to produce a valid slow
sample" blind spot. A window is stall-like only when one active source creates
at least one new Googlevideo connection, uploads request bytes, and receives
less than 128 KiB. Any meaningful delivery immediately clears the sequence.
Three consecutive matching windows produce `stall_suspected` with
`action:"escape_enabled"`, then start the challenge path:

```json
{"event":"stall_escape_trigger"}
```

The old node is only penalized after the challenger demonstrates real
Googlevideo delivery and is kept.

## Logging

JSONL events include passive samples, low-speed streaks, candidate results,
verified chains, pending recovery, selected nodes, killed connection IDs,
challenge samples, verdicts, rollbacks, external selector changes and
penalties. Normal passive windows now emit one semantic event rather than a
`passive_sample` plus `passive_sample_insufficient` pair. Each includes a
`status`, stall-window flag and current stall streak. The log rotates to `.1`
at the configured size.

## Deployed paths

```text
/usr/bin/oc-media-speed-select-v1
/etc/openclash/speed-select/config
/etc/openclash/custom/oc_media_patch_v1.rb
/etc/openclash/custom/openclash_custom_overwrite.sh  # append snippet before exit
/etc/crontabs/root                                   # once per minute
```

V1.4.1 replaced only the patcher rules. The existing selector, configuration,
patcher, overwrite hook and cron entry were retained. Future changes should use
the same lock, backup and atomic-replace procedure.
