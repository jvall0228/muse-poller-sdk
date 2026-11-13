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
- **Alive file.** Touched by the worker every iteration; fresh (< 3 min) means a worker is live. The hook uses it to avoid waking a second worker, and to know when a replacement is needed.
- **Stop file.** A single file whose existence tells the daemon and the workers to exit on their next loop check. Delete it and re-spawn to resume.
- **Rate-limit rules.** Jitter the poll sleep; back off on consecutive failures; log slow cycles; pass a cursor so most polls return nothing; never overlap calls.

## The rules, and what motivated each

Every operating rule in the skill traces to a failure or a measurement. A rule with no failure behind it is a preference, not a rule — these all have one.

### Worker poll matches your fastest producer

**The rule.** The worker can never see new work faster than work arrives, so a faster worker poll only wastes cycles. Single-producer queue → match the daemon (Discord 10s/10s, fleet-queue 60s/60s). Multi-producer queue (router + sibling workers handing off) → match the fastest producer's rate.

**Why.** The fleet-queue worker originally polled every 5s against a 60s daemon — 12 checks per possible delivery, 11 of which could not find anything new. The owner corrected it: "Worker poll and daemon poll should always match otherwise it's just wasting cycles." The refinement (fastest producer, not just the daemon) came from the Varisia orchestrator: its workers poll at 5s against a 10s router, which looks like a violation — but their queues have multiple producers (the router plus sibling workers handing off at any moment), so 5s is the right rate for the sibling-handoff producer. The scribe at 15s is the outlier: slower than its producers, so it can lag a dispatch by up to 15s.

### Hook baseline rule (seen_absent)

**The rule.** A hook must record when it looked and found no queue file. A file appearing between polls holds new work that must wake, not baseline. Only baseline when the file pre-existed the hook's first observation.

**The failure.** FLEET-0003 (Nov 13): a canary was queued by the daemon at 13:16:29, and the hook baselined over it at 13:16:43 — first sight of a freshly created queue file treated the new line as history. The canary sat ~11 min. The fix (in both wake scripts): the hook records `seen_absent: true` in its state when it polls and finds no queue file; the baseline branch fires only when the file pre-existed the hook's first observation.

### Daemon baseline rule

**The rule.** Only mark the daemon baselined when its first poll actually saw messages. If the first poll returns zero messages, stay unbaselined.

**The failure.** Found by adversarial review (Nov 13), not by an incident. The template's baseline branch set `baselined = True` even when the first poll returned zero messages, leaving `last_seen` stuck at the `"0"` sentinel — so the next poll treated the whole recent history as new work. The production fleet watcher had the same shape. It only escaped because the fleet channel had messages at baseline. Fixed in the template and in production.

### Hook prompt is a template, not a one-liner

**The rule.** The wake-time spawner instruction must carry four load-bearing requirements: the worker's poll interval and exit rule; spawn verification (retry once, report failure); "do not act yourself"; and the fact that the payload carries only the newest item.

**Why.** Found by adversarial review. The skill originally suggested a one-liner ("spawn the active worker subagent using the brief at <path>"). The production prompts carry four requirements the one-liner drops, and the spawn-verification clause matters most: the hook advances its watermark when it wakes, so a failed spawn is silent data loss — no re-wake until the *next* new item, and the queued item sits unhandled.

### Daemon health is a required tripwire

**The rule.** Every worker brief must include a liveness check: confirm the daemon process is alive and `last-seen.json` is fresh, and report if it is dead.

**Why.** The skill originally presented the liveness check as universal while templating it as optional — and the production fleet brief had none at all. A scaffolded fleet-style poller therefore had *no* tripwire: a dead daemon goes unnoticed until someone manually checks `last-seen.json` freshness. The template now makes it required, and the production fleet brief gained one.

### An old item naming you with no reply yet counts as outstanding

**The rule.** Never assume an old item was handled because time passed. If you find one, act on it or surface it.

**The failure.** FLEET-0002: a queue item mentioning the worker with no reply from the worker yet was missed because a watermark had seeded pre-existing items as seen. The lesson is now a per-task rule in the worker brief template and in the skill.

### Dry-run note (state 2 is untestable by dry-run alone)

**The rule.** A hook dry-run does not persist state, so the "file appears → WAKE" state is unreachable by dry-run alone on a fresh hook. Seed the state file with `{"seen_absent": true}` before dry-running, or test it live with `hooks.run`.

**Why.** Found by adversarial review. The skill prescribed dry-running all three hook states, but the template's `set_state()` is a no-op under dry-run, so the seen_absent recording never happens in a dry run. A fresh agent following the skill would either conclude the template is broken or — worse — accept the baseline as correct behavior, which is exactly the FLEET-0003 bug the skill exists to prevent.

## Why a skill, not a library

The agent is the runtime. A poller is not a program you install; it is a set of behaviors an agent performs (poll a source, classify, dispatch, act, report). A library would need a host process, a config format, and an operator — the skill needs only the agent and the templates. That is also why the skill is prompt-only (no `wisp.yaml`): there is no CLI entrypoint to declare. The templates are the deliverable.

## Why the worker never polls the source

The queue file is the worker's poll, and it is free. A worker that polls the source in a loop pays the source's rate limit on every iteration and duplicates the daemon's job. Per item, a few calls (read context + act) is fine; a loop is not.

## The instances

The templates were extracted from three live implementations. The full inventory, paths, and rate-limit numbers per source are in `local-subagent-poller/references/instances.md`.

1. **Varisia live play (Shape B, Nov 12).** Router + 4 slice workers, orchestrator routing, verified in session 2 (6 tasks routed, no errors). The only orchestrator — Shape B is proven-by-one.
2. **Discord mentions (Shape A, Nov 13).** A bot answers mentions in one server, only when a reply is warranted. REST poll, 10s. Warm reply ~23s. Cold-start test pending.
3. **Slack fleet-queue (Shape A, Nov 13).** Gateway read, 60s. Cold start measured (post → reply 4m 35s). Origin of the seen_absent rule.
