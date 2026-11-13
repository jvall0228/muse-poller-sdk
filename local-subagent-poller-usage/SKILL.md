---
name: local-subagent-poller-usage
description: Operate a poller built with the Subagent Poller SDK (local-subagent-poller) — start it, check its health, stop and resume it, and fix it when it stalls. Use for a poller that already exists; for scaffolding a new one, use local-subagent-poller instead.
---

# Using a Subagent Poller

## Purpose

Operate a poller built with the Subagent Poller SDK (`local-subagent-poller`) — start it, check its health, stop and resume it, and fix it when it stalls. This is the operator's skill. The SDK skill is the scaffolder's skill: it tells an agent how to *build* a poller. This one tells you (or an agent) how to *run* one that already exists.

Prompt-only skill — no CLI entrypoint, so no skill manifest.

## The pieces you're operating

Both shapes have the same pieces; what each is and how it works is defined in `docs/design.md` ("The shared core"). Where to find them on disk:

| Piece | Where it lives |
|---|---|
| Daemon, its config and adapter | The poller's directory; JSON-lines log on stderr, redirected to e.g. `~/hooks/logs/<name>-watcher.log` |
| Hook (Shape A) | `~/hooks/scripts/`; registered with `hooks.add` |
| Worker (Shape A), router and slice workers (Shape B) | Briefs in the poller's directory |
| Queue, `.cursor`, `queue.lock`, archives | `~/hooks/state/<poller>/` (queue archives are `queue.<UTC timestamp>.jsonl`) |
| Worker lock and alive file | `~/hooks/state/<poller>/worker.lock`, `worker-alive` |
| Heartbeat and markers | `last-seen.json`, `error.json`, `channel-warning.json` in the state dir |
| Stop file | `~/hooks/state/<poller>-stop` |
| High-water mark | `last-seen.json` (Shape A) or `last-dispatched-seq.txt` (Shape B) |

## Workflow — start a poller

**Shape A (two-tier):**
1. Register the hook first (`hooks.add`, 60s poll), then start the daemon in the background with output to a log file, e.g. `nohup python3 daemon.py --config <config> >> ~/hooks/logs/<name>-watcher.log 2>&1 &` (or `bun daemon.ts --config <config>`).
2. Confirm the daemon is alive (`ps` + the `baseline` event in its log). The first poll baselines the high-water mark and queues nothing.
3. Post a canary item in the source and verify the full path: daemon queues it → hook wakes → worker acts. Measure post-to-reply and record it. (Cold start after quiet: ~4.5 min; warm replies: seconds.)

**Shape B (orchestrator):**
1. Spawn all workers in one turn, in parallel (router + one subagent per slice, each with its brief).
2. Confirm each worker is running and the router is dispatching (check the high-water mark advancing and the queues receiving tasks).

## Workflow — the 30-second health check

Run this whenever replies stop or before a session:

1. **Daemon alive?** `ps` for the watcher process, `last-seen.json`'s `polled_at` fresh (threshold and why: design.md, "Daemon heartbeat and error markers"), and no `error.json`. A stale `polled_at` or an `error.json` means the queue is frozen, not quiet; judge by `polled_at`, never the file's mtime. A `channel-warning.json` means the daemon is running but one channel keeps failing: report it to the owner, do not restart for it. Recent log lines (`"level":"error"` / `"warn"`) say why.
2. **Cursor vs queue lines (Shape A).** The cursor equals the line count when the worker has caught up. If lines > cursor and no worker lock is held, a wake is due: check the hook's last decision (it stays silent for the startup window after a wake, and says "queue busy" while a rotation or append holds `queue.lock`). If the cursor lags with a worker alive, the worker is behind or dead. A cursor greater than the line count means the queue was just rotated and the cursor reset is not yet visible; the hook treats it as 0.
3. **Worker lock held?** `lock-holder.sh status --lock <worker.lock> --alive <worker-alive>` prints one JSON line. A held lock means a worker is live. A stale alive file with the lock held means the worker stopped touching it (a stall or a dying worker), and the holder releases the lock on its own past the stale limit.

## Workflow — stop and resume

- **Stop:** write the stop file. The daemon and all workers exit on their next loop check and report. For Shape A, also disable the hook — the hook does not check the stop file, so if items are queued when it is touched, it still wakes a worker that exits immediately (one wasted cold start).
- **Resume:** delete the stop file. Shape A: re-enable the hook and restart the daemon the way it was started (start location rule: the SDK skill, "Operating rules"). The daemon resumes from `last-seen.json` — no re-baseline, no lost items. Shape B: re-spawn all workers with fresh briefs; the router starts from the high-water mark and will not re-dispatch old events, and slice workers resume from their `.cursor` files.

## Operating rules

- **Never restart the daemon to "fix" a quiet queue.** A quiet queue with a fresh `polled_at` is working as designed. Restart only when the process is dead, an `error.json` exists, or `polled_at` is stale (health check, step 1).
- **Never delete the queue, the cursor, or the high-water mark to clear a stall.** That destroys the resume state and re-queues history. Fix the worker, then let it drain the backlog from its cursor. Archiving a fully consumed queue is the worker's job, through `rotate-queue.sh`.
- **A queue that stays empty is a failure signal, not idleness.** If a downstream queue (e.g. record-keeping) stays empty across a session, the upstream workers aren't sending tasks to it — the pipeline is broken, not idle.
- **One worker at a time per queue.** If two workers are alive on the same queue, stop one — the worker lock is what the hook uses to avoid this, so check the lock before spawning a manual replacement.
- **Sends are not idempotent.** When a send outcome is unknown, read the source before posting again — a blind retry can double post.

## Failure modes

- **A wake never lands (Shape A).** Check the cursor against the queue's line count and whether the worker lock is held (a failed spawn is retried after the startup window). If the hook baselined over a freshly created queue (its state has no `seen_absent` and no `baselined` flag), the item was swallowed — the fix is in the SDK skill (the seen_absent rule); as a workaround, append a new item to re-trigger a wake, and have the worker drain the backlog from its cursor.
- **A worker stalls on a slow step** (e.g. a large upload). Split slow steps into their own worker with a retry cap, so one stall can't freeze the rest. Cover any unanswered items manually in the meantime.
- **A dead daemon goes unnoticed.** The worker's liveness check is the only tripwire. On a stale `polled_at` or an `error.json`, restart the daemon and confirm the `baseline` event before trusting the queue again.
- **Double-handling.** Exactly-once routing depends on the high-water mark advancing after dispatch. If the router dies mid-dispatch, a resume may re-route — workers must tolerate a duplicate task idempotently; check the cursor before re-acting.
- **A worker exits but items remain.** The hook wakes a replacement on a later poll, once the startup window has passed (cursor-based outstanding — it does not wait for a new item). If no wake lands, spawn a worker manually from the brief so it drains the backlog.

## When to rebuild instead of operate

If the source, the routing table, the decision rules, or the poll rates change, that is a scaffold change — use the SDK skill (`local-subagent-poller`), not this one. This skill covers starting, stopping, health, and stalls only.

## Output Contract

When operating a poller, produce:
- A health verdict from the three checks above (daemon, cursor, lock and alive file) with the numbers, not a feeling.
- For a stop/resume: the stop file written (or deleted), the hook disabled (or re-enabled), and the workers' exit reports collected.
- For a stall: the item(s) covered manually, the cause found, and the fix applied — or the scaffold change named if the fix belongs in the SDK skill.
