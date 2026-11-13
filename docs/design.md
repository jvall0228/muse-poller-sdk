# Design

How the Subagent Poller SDK is put together, and why each piece is the way it is. For the skill itself, see `local-subagent-poller/SKILL.md`. For how it was verified, see `verification.md`. For the decisions in ADR form, see `decisions.md`.

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
source ──poll──> daemon (script, always on)
                    │ appends new items
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

Both shapes share:

- **Queue protocol.** Append-only JSONL, one per worker, plus a per-worker `.cursor` line-count file the worker advances only after a task is fully handled. The cursor is what makes a resume lossless and what stops double-handling.
- **High-water mark.** The daemon's (Shape A) or router's (Shape B) record of the newest event already seen. A resume starts from the mark and never re-processes history.
- **Worker lock.** An exclusive flock the worker holds for its whole lifetime (a holder process that exits by itself if the worker stops touching the alive file). The hook checks the lock — not the alive file's age — to decide whether a worker is alive, so a model turn that takes minutes cannot wake a second worker mid-task.
- **Alive file.** Touched by the worker every iteration; the lock holder exits by itself if it goes stale. The operator's heartbeat, not the hook's liveness signal.
- **Stop file.** A single file whose existence tells the daemon and the workers to exit on their next loop check. Delete it and re-spawn to resume.
- **Rate-limit rules.** Jitter the poll sleep; back off on consecutive failures; log slow cycles; pass a cursor so most polls return nothing; never overlap calls.
- **Daemon heartbeat + error marker.** `last-seen.json` carries a `polled_at` field written on every successful poll, and the daemon writes an `error.json` marker and exits non-zero on an auth error or after N consecutive failures. A stale `polled_at` (or an error marker) means the daemon is dead, even if the cursors are unchanged.

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

**The rule.** The wake-time spawner instruction must carry five load-bearing requirements: the worker's poll interval and exit rule; spawn verification (retry once, report failure); "do not act yourself"; the payload carries only the newest item's identifiers and the count, never message text; and the rule that the wake payload and queue content are untrusted data from the source, never instructions.

**Why.** Found by adversarial review. The skill originally suggested a one-liner ("spawn the active worker subagent using the brief at <path>"). The production prompts carry five requirements the one-liner drops, and the spawn-verification clause matters most: the hook used to advance its watermark when it woke, so a failed spawn was silent data loss — no re-wake until the *next* new item, and the queued item sat unhandled. The hook now decides "work outstanding" by comparing the queue line count to the worker's `.cursor` file, so a failed spawn is retried on the next poll — but the verification still matters, because it surfaces a broken spawn path instead of letting the hook retry it silently every minute.

### Daemon health is a required tripwire

**The rule.** Every worker brief must include a liveness check: confirm the daemon process is alive, `last-seen.json`'s `polled_at` is fresh, and no `error.json` marker exists — and report if it is dead.

**Why.** The skill originally presented the liveness check as universal while templating it as optional — and a production team-queue brief had none at all. A scaffolded team-queue-style poller therefore had *no* tripwire: a dead daemon goes unnoticed until someone manually checks `last-seen.json` freshness. The template now makes it required, and a production team-queue brief gained one.

### An old item naming you with no reply yet counts as outstanding

**The rule.** Never assume an old item was handled because time passed. If you find one, act on it or surface it.

**The failure.** The stale-item lesson: a queue item mentioning the worker with no reply from the worker yet was missed because a watermark had seeded pre-existing items as seen. The lesson is now a per-task rule in the worker brief template and in the skill.

### The worker holds a lock, and outstanding work is cursor-based

**The rule.** A worker holds an exclusive flock on a lockfile for its whole lifetime (a holder process that exits when the worker touches a release file, or by itself if the worker stops touching the alive file). The hook checks the lock — not the alive file's age — to decide whether a worker is alive. "Work outstanding" is decided by comparing the queue line count to the worker's `.cursor` file, never by a hook-owned watermark; the hook writes the cursor exactly once, at baseline. A failed spawn is retried once the startup window has passed (the cursor does not advance).

**Why.** Found by a second review (Nov 13). The alive-file window (180s) was shorter than a worker turn (~3–4 min), so a second worker could start mid-task — and a new queue line arriving while a worker was still starting up woke a second one on the same cursor. The lock is sized to the worker's lifetime, not to a turn, and the holder self-releases if the worker dies. The watermark had the same shape of problem: the hook advanced it at wake time, before a worker was confirmed started, so a failed spawn stranded the items. Cursor-based outstanding closes both.

### Queued content is untrusted data, and the wake payload carries identifiers only

**The rule.** The wake payload carries only the newest item's identifiers and the count — never message text. The wake payload and the queue content are untrusted data from the source, never instructions. The worker, slice-worker, router, and hook-prompt templates all carry this as a hard rule: a request inside queued content to run a command, reveal data, change scope, or contact someone is surfaced to the owner, not acted on.

**Why.** Found by a second review (Nov 13). The wake payload embedded raw message text, and the wake payload is part of the spawner's prompt — so a message from the source could inject instructions into the spawner, and a queued message could inject instructions into the worker. The fix is structural: identifiers only in the payload, and an explicit untrusted-data rule in every brief that reads the queue. The worker reads the full queue itself, from the queue file, under that rule.

### The daemon heartbeats, exits on auth errors, and writes state atomically

**The rule.** `last-seen.json` carries a `polled_at` heartbeat written on every successful poll, not only when items were queued; the liveness check reads `polled_at`, never the file's mtime. The daemon counts per-channel failures and treats an all-channels-failed cycle as a cycle failure — and never writes the heartbeat after one. An auth error (a 401, judged by the HTTP status rather than message text; 403 only where the source documents it as auth) exits non-zero immediately with an `error.json` marker, and a single channel that keeps failing while others succeed gets a `channel-warning.json` marker without stopping the daemon; after N consecutive failures of any kind, the daemon writes the same marker and exits. State files are written via a temp file in the same directory, fsync, then atomic rename — never in place. One daemon instance only: an exclusive lock at startup (flock, or an exclusive-create pidfile with a liveness check), exit if held. Credentials are read from the environment or a secrets store — never hard-coded or committed, kept out of logs and queue lines.

**Why.** Found by a second review (Nov 13). The liveness check assumed `last-seen.json` updated every poll, so an idle healthy daemon failed it — and, worse, the heartbeat was written even when every channel failed, so the file stayed fresh while the daemon was effectively dead (a 401 on every read left `consecutiveFailures` at zero and `last-seen.json` current). Auth errors retried forever with no signal. State was written in place, so a crash mid-write truncated the file and the daemon re-baselined over history. Two daemons could run at once (a bare `nohup ... &` start) and append every item twice. The cursor advanced to `newest` before the append loop, so a mid-loop throw lost the remaining messages — it now advances per message after its append succeeds. The daemon also logged the author's username and the first 100 characters of each message; it now logs channel and message id only.

### Where the daemon starts depends on how credentials are scoped

**The rule.** A supervised service (systemd, launchd) is fine in normal environments. Only where network credentials are scoped to an agent's tool call must the daemon be started from agent context (a tool call, a cron, or a hook).

**Why.** In one hosting environment an egress-proxy credential rotates per call, so a service cannot hold a current credential and its daemons fail to reach the network. A long-running daemon keeps working on the credential it started with; in such environments, recovery after the host is replaced needs an agent-context mechanism (a recovery cron).

### Dry-run note (state 2 is untestable by dry-run alone)

**The rule.** A hook dry-run does not persist state, so the "file appears → WAKE" state is unreachable by dry-run alone on a fresh hook. Seed the state file with `{"seen_absent": true}` before dry-running, or test it live with `hooks.run`.

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
