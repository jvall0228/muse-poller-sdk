# Using a Subagent Poller

## Purpose

Operate a poller built with the Subagent Poller SDK (`local-subagent-poller`) — start it, check its health, stop and resume it, and fix it when it stalls. This is the operator's skill. The SDK skill is the scaffolder's skill: it tells an agent how to *build* a poller. This one tells you (or an agent) how to *run* one that already exists.

Prompt-only skill — no CLI entrypoint, so no `wisp.yaml`.

## The pieces you're operating

Both shapes have the same pieces; what each is and how it works is defined in `../local-subagent-poller/docs/design.md` ("The shared core"). Where to find them on disk:

| Piece | Where it lives |
|---|---|
| Daemon, its config and adapter | The poller's directory (e.g. `~/workspace/fleet-queue-poller/daemon.py`, `~/workspace/discord-mentions/daemon.ts`); the daemon runs as `python3 daemon.py --config <config>` or `bun daemon.ts --config <config>`; JSON-lines log on stderr, redirected to e.g. `~/hooks/logs/<name>-watcher.log` |
| Hook (Shape A) | `~/hooks/scripts/`; registered with `hooks.add` |
| Worker (Shape A) | The poller's side chat agent — its brief lives in the side chat as a message; a file copy in the poller's directory is a superseded fallback where migrated (fleet-queue, Discord) |
| Router and slice workers (Shape B) | Briefs in the poller's directory |
| Queue, `.cursor`, `queue.lock`, archives | `~/hooks/state/<poller>/` (queue archives are `queue.<UTC timestamp>.jsonl`) |
| Worker lock and alive file | `~/hooks/state/<poller>/worker.lock`, `worker-alive` |
| Heartbeat and markers | `last-seen.json`, `error.json`, `channel-warning.json` in the state dir |
| Worker stop file | `~/hooks/state/<poller>-worker-stop` — stops workers only; the daemon keeps polling |
| Daemon stop file | `~/hooks/state/<poller>-stop` — stops the daemon; must equal `<state_root>/<stop_file_name>` in the daemon config and the registry's `stop_file` |
| Watchdog | `~/hooks/scripts/daemon-watchdog.sh`, registered with `hooks.add` (60s poll); registry `~/hooks/state/daemon-registry.json` |
| Activity side chat | One persistent side chat per poller — the Shape A worker's home; relayed handoffs land there, posted visibly |
| High-water mark | `last-seen.json` (Shape A) or `last-dispatched-seq.txt` (Shape B) |

## Workflow — start a poller

**Shape A (two-tier):**
1. Register the hook first (`hooks.add`, 60s poll), then start the daemon in the background with output to a log file, e.g. `nohup python3 daemon.py --config <config> >> ~/hooks/logs/<name>-watcher.log 2>&1 &` (or `bun daemon.ts --config <config>`).
2. Confirm the daemon is alive (`ps` + the `baseline` event in its log). The first poll baselines the high-water mark and queues nothing.
3. Post a canary item in the source and verify the full path: daemon queues it → hook hands off to main → main wakes the side chat agent → agent acts. Measure post-to-reply and record it. (Cold start after quiet: ~4.5 min; warm replies: seconds.)

**Shape B (orchestrator):**
1. Spawn all workers in one turn, in parallel (router + one subagent per slice, each with its brief).
2. Confirm each worker is running and the router is dispatching (check the high-water mark advancing and the queues receiving tasks).

## Workflow — the 30-second health check

Run this whenever replies stop or before a session:

1. **Daemon alive?** `ps` for the watcher process, `last-seen.json`'s `polled_at` fresh, and no `error.json`. Fresh means within poll interval + first backoff step + call timeout — for the production pollers: fleet-queue 60 + 60 + 60 = 180s, Discord mentions 10 + 30 + 10 = 50s. A stale `polled_at` or an `error.json` means the queue is frozen, not quiet; judge by `polled_at`, never the file's mtime. (Known gap: the Discord watcher's `last-seen.json` carries no `polled_at` yet, so its check is process-only until the new module daemon has run and rewritten it.) A `channel-warning.json` means the daemon is running but one channel keeps failing: report it to the owner, do not restart for it. Recent log lines (`"level":"error"` / `"warn"`) say why. If a watchdog hook is registered, check its last decision too — a daemon down with no recent wake means the watchdog itself needs attention (registry, hook state, or the hook's own log).
2. **Cursor vs queue lines (Shape A).** The cursor equals the line count when the worker has caught up. If lines > cursor and no worker lock is held, a wake is due: check the hook's last decision (it stays silent for the startup window after a wake, and says "queue busy" while a rotation or append holds `queue.lock`). If the cursor lags with a worker alive, the worker is behind or dead. A cursor greater than the line count means the queue was just rotated and the cursor reset is not yet visible; the hook treats it as 0.
3. **Worker lock held?** `lock-holder.sh status --lock <worker.lock> --alive <worker-alive>` prints one JSON line. A held lock means a worker is live. A stale alive file with the lock held means the worker stopped touching it (a stall or a dying worker), and the holder releases the lock on its own past the stale limit.

## Workflow — stop and resume

- **Stop the workers only:** write the worker stop file (`~/hooks/state/<poller>-worker-stop`). The side chat agent exits on its next loop check and reports as its final message in its chat; the daemon keeps polling and the queue keeps filling. The hook does not check either stop file, so for Shape A also disable the hook — otherwise, if items are queued when it is touched, it still hands off and main wakes an agent that exits immediately (one wasted cold start).
- **Stop the daemon only:** write the daemon stop file (`~/hooks/state/<poller>-stop`). The daemon exits on its next loop check. The watchdog DOES check the daemon stop file, so it will not wake a worker for a stopped daemon — leave it enabled. Workers already running keep draining the queue, then exit after 10 minutes quiet; no new items arrive while the daemon is down.
- **Stop everything:** disable the hook first (Shape A), then write both stop files. The order matters: if the worker stop file lands while the hook is still enabled, the hook hands off and main wakes an agent that exits immediately on it (one wasted cold start).
- **Never write one shared path for both.** Before 1.2.1 the two stop files were the same path, so stopping a worker also killed the daemon (2026-11-14: a redundant fleet-queue worker was stopped and the daemon exited with it). If you find a poller where the worker's `{{STOP_FILE}}` equals the daemon's stop file, give the worker the `-worker-stop` path first — the daemon's path stays as it is.
- **Resume:** delete the stop file(s) you wrote. Shape A: re-enable the hook (if disabled) and restart the daemon from agent context (a tool call or a cron — never systemd: the egress proxy credential rotates per tool call, so a systemd service can never hold a current credential) — if only the worker stop file was written, the daemon never stopped and there is nothing to restart. If a watchdog hook is registered and the daemon is dead, the watchdog restarts it on its next poll — or restart it yourself the way it was started. The daemon resumes from `last-seen.json` — no re-baseline, no lost items. Shape B: re-spawn all workers with fresh briefs; the router starts from the high-water mark and will not re-dispatch old events, and slice workers resume from their `.cursor` files. After resuming, verify both stop files are absent, the daemon process is alive with `polled_at` fresh, and (Shape A) the hook is re-enabled — a leftover stop file leaves the poller half-stopped (a leftover worker stop file wakes workers that exit at once; a leftover daemon stop file leaves the queue frozen).

## Operating rules

- **Never restart the daemon to "fix" a quiet queue.** A quiet queue with a fresh `polled_at` is working as designed. Restart only when the process is dead, an `error.json` exists, or `polled_at` is stale (health check, step 1).
- **Never delete the queue, the cursor, or the high-water mark to clear a stall.** That destroys the resume state and re-queues history. Fix the worker, then let it drain the backlog from its cursor. Archiving a fully consumed queue is the worker's job, through `rotate-queue.sh`.
- **A queue that stays empty is a failure signal, not idleness.** If a downstream queue (e.g. record-keeping) stays empty across a session, the upstream workers aren't sending tasks to it — the pipeline is broken, not idle.
- **One worker at a time per queue.** If two workers are alive on the same queue, stop one — the worker lock is what the hook uses to avoid this, so check the lock before spawning a manual replacement.
- **Sends are not idempotent.** When a send outcome is unknown, read the source before posting again — a blind retry can double post.

## Failure modes

- **A wake never lands (Shape A).** Check the cursor against the queue's line count and whether the worker lock is held (a failed handoff is retried after the startup window). If the hook baselined over a freshly created queue (its state has no `seen_absent` and no `baselined` flag), the item was swallowed — the fix is in the SDK skill (the seen_absent rule); as a workaround, append a new item to re-trigger a wake, and have the side chat agent drain the backlog from its cursor.
- **A worker stalls on a slow step** (e.g. a large upload). Split slow steps into their own worker with a retry cap, so one stall can't freeze the rest. Cover any unanswered items manually in the meantime.
- **A dead daemon goes unnoticed.** The watchdog hook is the tripwire: it wakes a worker to restart the daemon. The worker's liveness check is the backstop (it reports a dead daemon it cannot restart). On a stale `polled_at` or an `error.json`, restart the daemon and confirm the `baseline` event before trusting the queue again. If the watchdog is registered and the daemon stays down, check the watchdog's registry entry (pgrep pattern, heartbeat file) and its hook log — a bad pattern never wakes.
- **The watchdog never wakes.** Check the registry file exists and parses, the daemon ids are unique, and the hook is registered and enabled. A missing or unreadable registry ends each poll silently with the reason in the hook log — there is nothing to supervise, so no worker spawns.
- **Double-handling.** Exactly-once routing depends on the high-water mark advancing after dispatch. If the router dies mid-dispatch, a resume may re-route — workers must tolerate a duplicate task idempotently; check the cursor before re-acting.
- **A worker exits but items remain.** The hook hands off on a later poll, once the startup window has passed (cursor-based outstanding — it does not wait for a new item), and main wakes the side chat agent. If no wake lands, wake the side chat agent in its chat manually so it drains the backlog.

## When to rebuild instead of operate

If the source, the routing table, the decision rules, or the poll rates change, that is a scaffold change — use the SDK skill (`local-subagent-poller`), not this one. This skill covers starting, stopping, health, and stalls only.

## Output Contract

When operating a poller, produce:
- A health verdict from the three checks above (daemon, cursor, lock and alive file) with the numbers, not a feeling.
- For a stop/resume: which stop file was written (or deleted) — worker, daemon, or both — the hook disabled (or re-enabled), and the workers' exit reports collected.
- For a stall: the item(s) covered manually, the cause found, and the fix applied — or the scaffold change named if the fix belongs in the SDK skill.
