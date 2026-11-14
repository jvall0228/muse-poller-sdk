# Design

How the Subagent Poller SDK is put together, and why each piece is the way it is. This file is the home for mechanisms and the failures behind them. The build contract is `local-subagent-poller/SKILL.md`, operating a poller is `local-subagent-poller-usage/SKILL.md`, requirements are in the `README.md`, verification is `verification.md`, and the decisions in ADR form are `decisions.md`.

## The problem, precisely

Three mechanisms exist for waking an agent on an external event, and each fails a different requirement:

| Mechanism | Idle cost | Wake latency | Verdict |
|---|---|---|---|
| Hook (1/min poll) | Zero tokens | Minutes to land a wake | Too slow when seconds matter |
| Cron (1-min floor) | Zero tokens between runs | ≥ 1 min, plus a full agent turn | Too slow, and a full turn per check |
| Warm subagent | A small liveness trickle | Seconds | The accepted shape for live work |

The pattern exists because the work that needs seconds-fast replies (a player acting in a live game, a message landing in a queue) cannot wait for a hook or a cron. The tradeoff is explicit: a small background trickle (one liveness turn per worker every couple of minutes) in exchange for seconds-fast replies. When the work is intermittent rather than continuous, the two-tier form keeps the same seconds-fast active replies while idling at zero tokens — the price is a cold start (~4.5 min) on the first item after quiet.

## The two shapes

### Shape A — two-tier poller (intermittent work)

```
source ──poll──> daemon (script + source adapter, always on)
                    │ appends new items under queue.lock
                    ▼
              queue.jsonl (+ .cursor)
                    │ hook checks once a minute
                    ▼
              hook ──wake──> worker subagent (acts, exits after 10 min quiet)
```

The daemon and the hook are scripts (zero tokens). The worker only exists while work is live. The hook is the only thing that spends nothing and wakes something — and its wake path is the fragile part (see "The rules" below).

### Shape B — orchestrator (continuous session)

```
source ──poll──> router (subagent, always warm)
                    │ classify + dispatch (exactly once)
                    ▼
         ┌─────────┴─────────┐
    narrator.jsonl   combat.jsonl   voice.jsonl   scribe.jsonl
         │              │              │              │
    slice worker   slice worker   slice worker   slice worker
    (owns a slice, hands off to siblings by appending to their queues)
```

No hook, no idle exit. The router reasons about nothing and posts nothing. Each slice worker owns exactly one slice of state and no other worker touches it. Workers hand tasks to each other by appending to the right queue, never by direct calls. The session runs until the stop file is written.

## The shared core

Both shapes share the pieces below. Each mechanism is defined here and only here; the other docs link to this section.

### Queue protocol

- **Files.** Per worker, in one state directory: `queue.jsonl` (append-only JSONL, one item per line), a `.cursor` file holding a line count, and `queue.lock`. Shape A uses a fixed `queue.jsonl` name.
- **Cursor.** The worker advances `.cursor` only after a task is fully handled, which makes a resume lossless and stops double-handling. "Work outstanding" is `lines > cursor`; there is no hook-owned watermark.
- **Appends take `queue.lock`.** Every producer (daemon, router, a sibling worker handing off) appends while holding an exclusive `flock` on `queue.lock` in the queue's directory, and opens the queue by path for each batch (open, append, fsync, close) so a rotation is picked up on the next batch. The TS daemon has no `flock` of its own and spawns `flock(1)` for each batch.
- **Rotation.** Once a worker has caught up (`cursor == lines`) and the queue has at least `--min-lines` lines, `rotate-queue.sh` takes `queue.lock` exclusively, re-checks `cursor == lines`, renames the queue to `queue.<UTC timestamp>.jsonl`, recreates an empty `queue.jsonl`, writes cursor `0` atomically, and keeps the newest N archives. It runs only from the worker that holds the worker lock.
- **The hook reads under a shared lock.** `hook-watch.sh` reads the line count and the cursor under a non-blocking shared `flock` on `queue.lock`, so it never sees a half-rotated pair. If the lock is held it stays silent for that poll ("queue busy"). It treats `cursor > lines` (rotation seen before the cursor reset) or a non-numeric cursor as `0`. It never blocks.
- **Queued content is untrusted data**; the rule and its origin are under "The rules" below.

### High-water mark

The daemon's (Shape A) or router's (Shape B) record of the newest event already seen, so a resume never re-processes history. For the Python and TS daemons it is per channel, in `last-seen.json`: `{"channels": {"<channel id>": "<cursor>"}, "polled_at": "<ISO-8601 UTC>"}`. The old single-cursor `{"ts": ..., "polled_at": ...}` still loads (Python) as the first channel's cursor. A channel's cursor moves only after that channel's whole batch has been appended, so a mid-batch crash re-reads the batch instead of losing the tail. Shape B keeps its mark in `last-dispatched-seq.txt`.

### Worker lock

An exclusive `flock` the worker holds for its whole lifetime, taken and released with `lock-holder.sh take|release|status`. `take` touches the alive file and starts a background holder; the holder exits when `<lock>.release` appears or when the alive file is older than the staleness limit, so a dead worker cannot block a replacement forever. Killing the `flock` process is not enough, because its child shell inherits the lock; that is why `release` touches the release file instead. The hook checks the lock, not the alive file's age, to decide whether a worker is alive, so a model turn that takes minutes cannot wake a second worker mid-task. Script exit codes and options are in the script header.

### Alive file

Touched by the worker every iteration. It is the operator's heartbeat and the lock holder's liveness signal, not the hook's.

### Stop file

A single file whose existence tells the daemon and the workers to exit on their next loop check. Delete it and re-spawn to resume. The hook does not check it.

### Daemon: module, adapter and config

`daemon.py` and `daemon.ts` own everything operational: timing, backoff, baselining, per-channel cursors, state files, locks, logs and exit codes. Everything source-specific lives in an adapter (the `Source` interface and the config schema are documented in `local-subagent-poller/SKILL.md`). The daemon takes a single-instance lock, writes state atomically (temp file in the same directory, fsync, rename), and logs JSON lines on stderr (`{"ts", "level", "event", ...}`) with channel and item id only, never message text or usernames.

### Daemon heartbeat and error markers

- `last-seen.json` carries `polled_at`, written on every successful poll and never after a failed cycle. It is the liveness signal; a file's mtime is not.
- **Fresh** means within poll interval + first backoff step + call timeout. One failed cycle skips the heartbeat and sleeps at least the first backoff step, so a bare 2x-interval threshold trips on one transient failure.
- `error.json` means the daemon gave up (a 401, or `max_failures` consecutive failed cycles) and exited non-zero: restart it.
- `channel-warning.json` means the daemon is running but one channel failed `max_failures` cycles in a row while the others succeeded: report it, do not restart for it.
- A stale `polled_at` or an `error.json` means the daemon is dead and the queue is frozen, not quiet.

### Daemon supervision (watchdog)

One hook supervises all daemons, from a registry (`daemon-registry.json`): one entry per daemon with its pgrep pattern, heartbeat file, stale threshold, stop file and start command. Every 60s it checks each daemon — process alive (anchored `pgrep`, both ends) AND heartbeat fresh (`polled_at` within poll interval + first backoff step + call timeout, the same threshold as "Fresh" above). A daemon whose stop file exists is intentionally stopped and skipped. It wakes a worker only when a daemon is down, and only once per cooldown per daemon. The wake payload names the daemons this wake covers and why — identifiers only, never logs or message text. The worker re-checks the stop file and `pgrep` before starting, so a manual restart between the hook's check and the worker's start is not duplicated; for a hung daemon (process alive, heartbeat stale or missing) it re-reads `polled_at`, and if still stale terminates the process, confirms it is gone, then starts it from the registry. The `pgrep` pattern matches the full command line including arguments (for the SDK daemon, `^python3 .*/daemon\.py --config .*$`) and an alternation must be grouped. A daemon that keeps failing (it wrote `error.json` and exits on every restart) is woken at most `MAX_CONSECUTIVE_WAKES` times in a row (default 3), then the hook goes silent for it with a "gave up" reason until it is seen healthy or its stop file is toggled; the worker stops with FAILED on an auth error instead of restarting. Config errors (unfilled placeholder, non-numeric cooldown, unparseable `polled_at`, an entry that is rejected) are named in the silent reason and are never reported as "healthy". This replaces a recovery cron: it is event-driven (wakes only on a real outage) and recovers in ~1–2 min instead of up to an hour, and it spends no tokens while idle.

### Rate-limit rules

Jitter the poll sleep; back off on consecutive failures and reset on the first success; log slow cycles; pass a cursor so most polls return nothing; never overlap calls (the call timeout is at most the poll interval). Rate-limit retry (prompt, `retry_after` seconds) lives in the adapter and is separate from failure backoff (minutes), which lives in the daemon.

### Dependencies

`flock(1)` (util-linux) is needed by the worker lock, queue rotation, the hook's shared read, and the TS daemon's appends. The watchdog script additionally needs `pgrep(1)` and GNU `date`. The full list is in the `README.md`.

## The rules, and what motivated each

Every operating rule in the skill traces to a failure or a measurement. A rule with no failure behind it is a preference, not a rule — these all have one.

### Worker poll matches your fastest producer

**The rule.** The worker can never see new work faster than work arrives, so a faster worker poll only wastes cycles. Single-producer queue → match the daemon (chat mentions 10s/10s, team queue 60s/60s). Multi-producer queue (router + sibling workers handing off) → match the fastest producer's rate.

**Why.** The team-queue worker originally polled every 5s against a 60s daemon — 12 checks per possible delivery, 11 of which could not find anything new. The owner corrected it: "Worker poll and daemon poll should always match otherwise it's just wasting cycles." The refinement (fastest producer, not just the daemon) came from the live game session's orchestrator: its workers poll at 5s against a 10s router, which looks like a violation — but their queues have multiple producers (the router plus sibling workers handing off at any moment), so 5s is the right rate for the sibling-handoff producer. The scribe at 15s is the outlier: slower than its producers, so it can lag a dispatch by up to 15s.

### Hook baseline rule (seen_absent)

**The rule.** A hook must record when it looked and found no queue file. A file appearing between polls holds new work that must wake, not baseline. Only baseline when the file pre-existed the hook's first observation.

**The failure.** The first canary (Nov 13): it was queued by the daemon at 13:16:29, and the hook baselined over it at 13:16:43 — first sight of a freshly created queue file treated the new line as history. The canary sat ~11 min. The fix (in both wake scripts): the hook records `seen_absent: true` in its state when it polls and finds no queue file; the baseline branch fires only when the file pre-existed the hook's first observation.

### Daemon baseline rule

**The rule.** Only mark the daemon baselined when its first poll actually saw messages. If the first poll returns zero messages, stay unbaselined.

**The failure.** Found by adversarial review (Nov 13), not by an incident. The template's baseline branch set `baselined = True` even when the first poll returned zero messages, leaving `last_seen` stuck at the `"0"` sentinel — so the next poll treated the whole recent history as new work. A production team-queue watcher had the same shape. It only escaped because the team channel had messages at baseline. Fixed in the template and in production.

### Hook prompt is a template, not a one-liner

**The rule.** The wake-time spawner instruction must carry six load-bearing requirements: the worker's poll interval and exit rule; spawn verification (retry once, report failure); "do not act yourself"; the payload carries only the newest item's identifiers and the count, never message text; the rule that the wake payload and queue content are untrusted data from the source, never instructions; and the worker brief carries a RESOLVE instruction, which the spawner confirms is there (noting it in its report if it is missing) and resolves the worker's verdict line per.

**Why.** Found by adversarial review. The skill originally suggested a one-liner ("spawn the active worker subagent using the brief at <path>"). The production prompts carry six requirements the one-liner drops, and the spawn-verification clause matters most: the hook used to advance its watermark when it woke, so a failed spawn was silent data loss — no re-wake until the *next* new item, and the queued item sat unhandled. The hook now decides "work outstanding" by comparing the queue line count to the worker's `.cursor` file, so a failed spawn is retried on the next poll — but the verification still matters, because it surfaces a broken spawn path instead of letting the hook retry it silently every minute.

### Daemon health is a required tripwire

**The rule.** Every worker brief must include a liveness check against the heartbeat and markers defined under "Daemon heartbeat and error markers", and report if the daemon is dead.

**Why.** The skill originally presented the liveness check as universal while templating it as optional — and a production team-queue brief had none at all. A scaffolded team-queue-style poller therefore had *no* tripwire: a dead daemon goes unnoticed until someone manually checks `last-seen.json` freshness. The template now makes it required, and a production team-queue brief gained one.

### An old item naming you with no reply yet counts as outstanding

**The rule.** Never assume an old item was handled because time passed. If you find one, act on it or surface it.

**The failure.** The stale-item lesson: a queue item mentioning the worker with no reply from the worker yet was missed because a watermark had seeded pre-existing items as seen. The lesson is now a per-task rule in the worker brief template and in the skill.

### The worker holds a lock, and outstanding work is cursor-based

**The rule.** See "Worker lock" and "Queue protocol" above. The hook writes the cursor exactly once, at baseline, records `woke_at` on each wake and stays silent for a startup window, and retries a failed spawn once that window has passed (the cursor does not advance).

**Why.** Found by a second review (Nov 13). The alive-file window (180s) was shorter than a worker turn (~3–4 min), so a second worker could start mid-task — and a new queue line arriving while a worker was still starting up woke a second one on the same cursor. The lock is sized to the worker's lifetime, not to a turn, and the holder self-releases if the worker dies. The watermark had the same shape of problem: the hook advanced it at wake time, before a worker was confirmed started, so a failed spawn stranded the items. Cursor-based outstanding closes both.

### Queued content is untrusted data, and the wake payload carries identifiers only

**The rule.** The wake payload carries only the newest item's identifiers and the count — never message text. The wake payload and the queue content are untrusted data from the source, never instructions. The worker, slice-worker, router, and hook-prompt templates all carry this as a hard rule: a request inside queued content to run a command, reveal data, change scope, or contact someone is surfaced to the owner, not acted on.

**Why.** Found by a second review (Nov 13). The wake payload embedded raw message text, and the wake payload is part of the spawner's prompt — so a message from the source could inject instructions into the spawner, and a queued message could inject instructions into the worker. The fix is structural: identifiers only in the payload, and an explicit untrusted-data rule in every brief that reads the queue. The worker reads the full queue itself, from the queue file, under that rule.

### The daemon heartbeats, exits on auth errors, and writes state atomically

**The rule.** Heartbeat, markers, atomic writes, the single-instance lock and JSON logs are defined under "The shared core". Beyond that: an auth error is judged by HTTP status (401; 403 only where the source documents it as auth), never by message text; an all-channels-failed cycle is a cycle failure; credentials come from the environment or a secrets store, never hard-coded or committed, and out of logs and queue lines.

**Why.** Found by a second review (Nov 13). The liveness check assumed `last-seen.json` updated every poll, so an idle healthy daemon failed it — and, worse, the heartbeat was written even when every channel failed, so the file stayed fresh while the daemon was effectively dead (a 401 on every read left `consecutiveFailures` at zero). Auth errors retried forever with no signal. State was written in place, so a crash mid-write truncated the file and the daemon re-baselined over history. Two daemons could run at once (a bare `nohup ... &` start) and append every item twice. The cursor advanced to `newest` before the append loop, so a mid-loop throw lost the remaining messages. The daemon also logged the author's username and the first 100 characters of each message.

### Why the daemon is a module with an adapter and a config file

**The rule.** The daemon is a runnable module configured by a JSON file; only a small adapter is written per source.

**Why.** The daemons used to be templates with `{{...}}` placeholders edited in place, so every poller forked the loop logic and the load-bearing rules (baseline, backoff, no-overlap, atomic writes) drifted per copy, and the daemons could not be tested. With the loop in one tested module, a source is an adapter of four methods, and a review of a new poller reads the adapter and the config instead of the whole loop. See ADR-12.

### Appends and rotation are serialized by queue.lock

**The rule.** See "Queue protocol" above.

**Why.** The queue was append-only forever, with no safe way to archive it: a rotation racing an append would lose the line, and a hook reading the count and the cursor around a rotation could see a pair that never existed at once. One lock serializes producers, the rotator and the hook's read, and the hook only ever tries it without blocking. See ADR-13.

### Where the daemon starts depends on how credentials are scoped

**The rule.** A supervised service (systemd, launchd) is fine in normal environments. Only where network credentials are scoped to an agent's tool call must the daemon be started from agent context (a tool call, a cron, or a hook).

**Why.** In one hosting environment an egress-proxy credential rotates per call, so a service cannot hold a current credential and its daemons fail to reach the network. A long-running daemon keeps working on the credential it started with; in such environments, recovery after the host is replaced needs an agent-context mechanism (a watchdog hook).

### One watchdog supervises all daemons

**The rule.** One watchdog hook supervises every daemon from one registry. It wakes a worker only when a daemon is down, only once per cooldown per daemon, and never for a daemon whose stop file exists. The worker re-checks the stop file and `pgrep` immediately before starting, so a restart that already happened is not duplicated.

**Why.** Two watchdogs share no cooldown state and would double-wake for the same down daemon; the worker's re-check is the backstop, not the plan. A recovery cron is the alternative it replaces: a full agent turn per check, up to an hour to notice an outage, and a turn spent even when nothing is wrong. The watchdog is a hook (zero tokens while idle) that only spends when a daemon is actually down — and a systemd service cannot be the recovery mechanism at all where credentials rotate per tool call (see above).

### Transparency is a decision at the resolve gate

**The rule.** Every hook-spawned (Shape A) worker brief carries a RESOLVE instruction (`{{RESOLVE_MODE}}`: `always` / `on-unexpected`), and the worker's exit report ends in a verdict line (ACTED / UNEXPECTED / FAILED / ROUTINE). For the poller hook, the spawner resolves the verdict: surface the report unless it is ROUTINE and the mode is `on-unexpected`. The watchdog worker resolves its own report the same way — its hook's prompt is the brief, so there is no separate spawner. Routine silence is the correct default. Relayed handoffs go to the poller's activity side chat, which posts them visibly and stays silent otherwise.

**Why.** Two transparency probes (Nov 13) looked like delivery failures and were not: the workers ran the check and chose silence because "daemons stopped as intended" is the expected state — there was nothing to report, and no handoff was ever created. The failure mode that is real is the opposite one: a handoff that arrives with a post request buried inside it is not followed (the receiving agent stays silent), while a direct instruction to post is. So the resolve decision has to be explicit in two places — the brief names how the worker's report resolves, and the hook prompt names how the spawner resolves the verdict — and the visible post has to go through one persistent side chat per poller, not through a handoff's buried request.

### Dry-run note (state 2 is untestable by dry-run alone)

**The rule.** A hook dry-run does not persist state, so the "file appears → WAKE" state is unreachable by dry-run alone on a fresh hook. The seeding procedure and the full list of hook states are in `local-subagent-poller/SKILL.md`.

**Why.** Found by adversarial review. The skill prescribed dry-running all four hook states, but the template's `set_state()` is a no-op under dry-run, so the seen_absent recording never happens in a dry run. A fresh agent following the skill would either conclude the template is broken or — worse — accept the baseline as correct behavior, which is exactly the first-canary bug the skill exists to prevent.

## Why a skill, not a library

The agent is the runtime. A poller is not a program you install; it is a set of behaviors an agent performs (poll a source, classify, dispatch, act, report). A library would need a host process, a config format, and an operator — the skill needs only the agent and the templates. That is also why the skill is prompt-only (no skill manifest): there is no CLI entrypoint to declare. The templates are the deliverable.

## Why the worker never polls the source

The queue file is the worker's poll, and it is free. A worker that polls the source in a loop pays the source's rate limit on every iteration and duplicates the daemon's job. Per item, a few calls (read context + act) is fine; a loop is not.

## The instances

The templates were extracted from three live implementations. The full inventory, paths, and rate-limit numbers per source are in `local-subagent-poller/references/instances.md`.

1. **Live game session (Shape B, Nov 12).** Router + 4 slice workers, orchestrator routing, verified in session 2 (6 tasks routed, no errors). The only orchestrator — Shape B is proven-by-one.
2. **Chat mentions (Shape A, Nov 13).** A bot answers mentions in one server, only when a reply is warranted. REST poll, 10s. Warm reply ~23s. Cold-start test pending.
3. **Team chat queue (Shape A, Nov 13).** Gateway read, 60s. Cold start measured (post → reply 4m 35s). Origin of the seen_absent rule.
