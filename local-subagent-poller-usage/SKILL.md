---
name: local-subagent-poller-usage
description: Operate a poller built with the Subagent Poller SDK (local-subagent-poller) — start it, check its health, stop and resume it, and fix it when it stalls. Use for a poller that already exists; for scaffolding a new one, use local-subagent-poller instead.
---

# Using a Subagent Poller

## Purpose

Operate a poller built with the Subagent Poller SDK (`local-subagent-poller`) — start it, check its health, stop and resume it, and fix it when it stalls. This is the operator's skill. The SDK skill is the scaffolder's skill: it tells an agent how to *build* a poller. This one tells you (or an agent) how to *run* one that already exists.

Prompt-only skill — no CLI entrypoint, so no skill manifest.

## The pieces you're operating

A poller built with the SDK has the same pieces in both shapes:

| Piece | What it is | Where it lives |
|---|---|---|
| **Daemon** | Background script, always on. Polls the source, appends new items to the queue, maintains `last-seen.json` (with a `polled_at` heartbeat written on every successful poll). Holds an exclusive lock so two instances cannot run; writes an `error.json` marker and exits non-zero on an auth error or after N consecutive failures. | The poller's directory (e.g. `watcher.py` / `watcher.ts`); log under `~/hooks/logs/` |
| **Hook** (Shape A) | Bash script, checks the queue once a minute. Wakes a worker only when new lines exist AND no worker is alive (no lock held). Decides "work outstanding" by comparing the queue line count to the worker's `.cursor` file — never by a hook-owned watermark. | `~/hooks/scripts/`; registered with `hooks.add` |
| **Worker** (Shape A) | Subagent that consumes the queue, acts on items, touches the alive file every iteration, holds the worker lock for its whole lifetime, exits after 10 min quiet. | Brief in the poller's directory |
| **Router + slice workers** (Shape B) | Router polls the source and dispatches to N queues; each slice worker stays warm and owns one slice. No hook, no idle exit. | Briefs in the poller's directory |
| **Queue** | Append-only JSONL, one per worker, plus a `.cursor` line-count file the worker advances only after a task is fully handled. | `~/hooks/state/<poller>/` |
| **Worker lock** | Exclusive flock the worker holds for its whole lifetime. The hook checks the lock — not the alive file's age — to decide whether a worker is alive. | `~/hooks/state/<poller>/worker.lock` |
| **Alive file** | Touched by the worker every iteration. The operator's heartbeat: a recent mtime means the worker is iterating. A model turn can take several minutes, so a stale alive file with the lock held only matters once it is older than `{{LOCK_STALE_SECS}}`; the lock holder exits by itself past that window. | `~/hooks/state/<poller>/worker-alive` |
| **Error marker** | `error.json` in the state dir. The daemon writes it and exits non-zero on an auth error or after N consecutive failures. Its presence means the daemon gave up — restart it, do not wait for it. | `~/hooks/state/<poller>/error.json` |
| **Stop file** | A single file whose existence tells the daemon and the workers to exit on their next loop check. | `~/hooks/state/<poller>-stop` |
| **High-water mark** | The router's (Shape B) or daemon's (Shape A) record of the newest event already seen, so a resume never re-processes history. | `last-seen.json` (Shape A) or `last-dispatched-seq.txt` (Shape B) |

## Workflow — start a poller

**Shape A (two-tier):**
1. Register the hook first (`hooks.add`, 60s poll), then start the daemon in the background with output to a log file, e.g. `nohup python3 <daemon>.py >> ~/hooks/logs/<name>-watcher.log 2>&1 &` (or `bun <daemon>.ts` as a background process for a TS daemon).
2. Confirm the daemon is alive (`ps` + the `baseline at ts ...` line in its log). The first poll baselines the high-water mark and queues nothing.
3. Post a canary item in the source and verify the full path: daemon queues it → hook wakes → worker acts. Measure post-to-reply and record it. (Cold start after quiet: ~4.5 min; warm replies: seconds.)

**Shape B (orchestrator):**
1. Spawn all workers in one turn, in parallel (router + one subagent per slice, each with its brief).
2. Confirm each worker is running and the router is dispatching (check the high-water mark advancing and the queues receiving tasks).

## Workflow — the 30-second health check

Run this whenever replies stop or before a session:

1. **Daemon alive?** `ps` for the watcher process, `last-seen.json`'s `polled_at` (an ISO-8601 UTC timestamp) within the threshold, and no `error.json` marker. The threshold is poll interval + first backoff step + call timeout (or simply 2× the poll interval plus the first backoff step): a single failed cycle skips the heartbeat and sleeps at least the first backoff step, so a bare 2× threshold trips on one transient failure. A `polled_at` stale past it (or an error marker) means the queue is frozen, not quiet. Do not judge by the file's mtime: the daemon writes `polled_at` on every successful poll, so a quiet source still updates it — an idle healthy daemon has a fresh `polled_at`, and a file whose `polled_at` is stale is a dead daemon. A `channel-warning.json` marker (multi-channel daemon) means the daemon is running but one or more channels keep failing — report it to the owner; do not restart for it.
2. **Cursor vs queue lines (Shape A).** The cursor should equal the line count when the worker has caught up. If lines > cursor and no worker is alive (no lock held), a wake is due — check the hook's log for the last decision (it stays silent for the startup window after a wake). If the cursor lags with a worker alive, the worker is behind or dead — check the lock and the alive file. There is no hook-owned watermark.
3. **Worker lock held?** If the lock is held, a worker is live. The alive file is the operator's heartbeat; a model turn can take several minutes, so a stale alive file with the lock held only matters once it is older than `{{LOCK_STALE_SECS}}` — then the worker stopped touching it (a stall or a dying worker) and the holder releases the lock on its own.

## Workflow — stop and resume

- **Stop:** write the stop file. The daemon and all workers exit on their next loop check and report. For Shape A, also disable the hook — the hook does not check the stop file, so if items are queued when it is touched, it still wakes a worker that exits immediately (one wasted cold start).
- **Resume:** delete the stop file. Shape A: re-enable the hook and restart the daemon the way it was started (a supervised service is fine normally; only where network credentials are scoped to an agent's tool call must it be restarted from agent context — see the SDK skill). The daemon resumes from `last-seen.json` — no re-baseline, no lost items. Shape B: re-spawn all workers with fresh briefs; the router starts from the high-water mark and will not re-dispatch old events, and slice workers resume from their `.cursor` files.

## Operating rules

- **Never restart the daemon to "fix" a quiet queue.** A quiet queue with a fresh `last-seen.json` `polled_at` is working as designed. Restart only when the process is dead, an `error.json` marker exists, or `polled_at` is stale past the health-check threshold.
- **Never delete the queue, the cursor, or the high-water mark to clear a stall.** That destroys the resume state and re-queues history. Fix the worker, then let it drain the backlog from its cursor.
- **A queue that stays empty is a failure signal, not idleness.** If a downstream queue (e.g. record-keeping) stays empty across a session, the upstream workers aren't sending tasks to it — the pipeline is broken, not idle.
- **One worker at a time per queue.** If two workers are alive on the same queue, stop one — the worker lock is what the hook uses to avoid this, so check the lock before spawning a manual replacement.
- **Sends are not idempotent.** When a send outcome is unknown, read the source before posting again — a blind retry can double post.

## Failure modes

- **A wake never lands (Shape A).** Check the cursor against the queue's line count and whether the worker lock is held. A failed spawn is retried once the startup window has passed (the cursor does not advance). If the hook baselined over a freshly created queue (its state has no `seen_absent` and no `baselined` flag), the item was swallowed — the fix is in the SDK skill (the seen_absent rule); as a workaround, append a new item to re-trigger a wake, and have the worker drain the backlog from its cursor.
- **A worker stalls on a slow step** (e.g. a large upload). Split slow steps into their own worker with a retry cap, so one stall can't freeze the rest. Cover any unanswered items manually in the meantime.
- **A dead daemon goes unnoticed.** The worker's liveness check is the only tripwire — if the daemon's `last-seen.json` `polled_at` goes stale or an `error.json` marker exists, restart the daemon and confirm the baseline log line before trusting the queue again.
- **Double-handling.** Exactly-once routing depends on the high-water mark advancing after dispatch. If the router dies mid-dispatch, a resume may re-route — workers must tolerate a duplicate task idempotently; check the cursor before re-acting.
- **A worker exits but items remain.** The hook wakes a replacement on a later poll, once the startup window has passed (cursor-based outstanding — it does not wait for a new item). If no wake lands, spawn a worker manually from the brief so it drains the backlog.

## When to rebuild instead of operate

If the source, the routing table, the decision rules, or the poll rates change, that is a scaffold change — use the SDK skill (`local-subagent-poller`), not this one. This skill covers starting, stopping, health, and stalls only.

## Output Contract

When operating a poller, produce:
- A health verdict from the three checks above (daemon, cursor, lock and alive file) with the numbers, not a feeling.
- For a stop/resume: the stop file written (or deleted), the hook disabled (or re-enabled), and the workers' exit reports collected.
- For a stall: the item(s) covered manually, the cause found, and the fix applied — or the scaffold change named if the fix belongs in the SDK skill.
