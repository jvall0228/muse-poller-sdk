# Subagent Poller SDK

Warm subagents plus plain script pollers, for seconds-fast replies to live events — when hooks and crons are too slow. A skill kit (prompt-only, no code library) for scaffolding pollers: an agent reads the skill, copies the templates, fills in the placeholders, and gets a working poller.

## The problem

Some work needs a reply in seconds when an external event happens: a player acts in a live game, a message lands in a queue, a device changes state. The scheduled mechanisms idle cheap but wake slow — hooks idle at zero tokens but take minutes to land a wake; crons poll at most once a minute. When seconds matter, the answer is to keep the agents warm and let dumb scripts do the watching.

## Two shapes, one core

Both shapes share one core: the queue protocol (append-only JSONL + cursor + high-water mark), the alive file, the worker lock, the stop file, the daemon heartbeat, and the rate-limit rules.

| Shape | When | How | Cost |
|---|---|---|---|
| **A — two-tier poller** | Work arrives in bursts with quiet gaps | Daemon polls the source and appends to a queue; a hook wakes a worker only when new work exists; the worker acts and exits after 10 min quiet | Zero tokens while idle; the first reply after quiet pays a cold start |
| **B — orchestrator** | A session is continuously live | A router polls the source, classifies each event, and dispatches to N slice-worker queues; each slice worker stays warm and owns one slice | A small liveness trickle per worker; replies land in seconds, always |

## Requirements

Shape A depends on a specific hook runtime — the one this SDK was extracted from. If your runtime is different, you must supply the equivalent of each piece before Shape A will work.

- **Hook runtime.** The hook script (`templates/hook-watch.sh`) sources `$HATCH_HOOK_RUNTIME`, which provides `hook_state_get` / `hook_state_set` (persistent per-hook JSON state), `silent <reason> <payload>` (end the poll quietly), and `wake <reason> <payload>` (spawn the worker). The hook is registered with `hooks.add` (60s poll interval, prompt from `templates/hook-prompt.md`) and tested with `hooks.dry_run` / `hooks.run`. On another runtime, supply equivalents: a per-hook state store, a silent outcome, a wake/spawn outcome, and a way to register a 60s poll with a prompt.
- **Bash + `jq` + `flock(1)`.** The hook script is bash and uses `jq` for state and payload JSON; the worker lock uses `flock(1)` (util-linux; on macOS it is not installed by default — install it separately, e.g. via a package manager). The `stat` calls fall back from GNU `stat -c %Y` to BSD `stat -f %m`, and bash 3.2+ works, but the lock needs flock.
- **Python 3 (for `daemon.py`) or bun (for `daemon.ts`).** The Python daemon uses the standard library only. The TS daemon needs bun and `node:fs`. Pick the template that matches your source, not your preference: Python/CLI sources → `daemon.py`; REST sources with per-channel cursors → `daemon.ts`.
- **Shape B needs no hook runtime.** The orchestrator is subagents only (router + slice workers), so it runs anywhere an agent can be spawned and a queue file can be appended to.

## Measured latencies

- **Shape A cold start (team chat queue, clean run):** post → reply 4m 35s; wake → reply 3m 42s. Daemon 18s, hook 35s. The worker's cold start + model turn + post dominates (~3–4 min).
- **Shape A warm reply (Discord, "yo" test):** ~23s end-to-end.
- **Shape B (live game session):** replies in seconds; 6 tasks routed with no errors in the verified session.

## Layout

```
local-subagent-poller/          The SDK skill (scaffolder's skill)
  SKILL.md                      The skill: two shapes, the pieces, the workflow, the rules
  templates/
    daemon.py                   Tier-1 daemon template (Python)
    daemon.ts                   Tier-1 daemon template (bun/TS, Discord-like sources)
    hook-watch.sh               Wake-hook script template (Shape A)
    hook-prompt.md              Wake-time spawner instruction template (Shape A)
    worker-brief.md             Active-worker brief template (Shape A)
    router-brief.md             Router brief template (Shape B)
    slice-worker-brief.md       Slice-worker brief template (Shape B)
  references/
    instances.md                The three live implementations the templates were extracted from

local-subagent-poller-usage/    The operator's skill: run a built poller
  SKILL.md                      Start, health-check, stop/resume, troubleshoot

docs/
  design.md                     The design: why the shapes exist, the rules and what motivated each
  verification.md               How it was verified: adversarial review, template checks, live tests
  review-guide.md               For reviewers: what to check, the known gaps, the open questions
  decisions.md                  The decisions and their rationale
```

## How to use it

1. Read `local-subagent-poller/SKILL.md` (or load the skill in your agent).
2. Decide the shape: intermittent work → Shape A; continuous session → Shape B.
3. Copy the templates into the new poller's directory and fill in the `{{...}}` placeholders.
4. Register the hook first (Shape A), then start the daemon, wait for its baseline log line, then post a canary item and measure post-to-reply.
5. To operate a built poller (start, health-check, stop/resume, troubleshoot), read `local-subagent-poller-usage/SKILL.md`.

## Rules that matter

- **Worker poll matches your fastest producer.** A worker can never see new work faster than work arrives, so a faster worker poll only wastes cycles.
- **Hook baseline rule (seen_absent).** A hook must record when it looked and found no queue file — a file appearing between polls holds new work that must wake, not baseline.
- **Daemon baseline rule.** Only mark the daemon baselined when its first poll actually saw messages.
- **Daemon health is a required tripwire.** Every worker brief must include a liveness check (daemon process alive, `last-seen.json`'s `polled_at` fresh within poll interval + first backoff step + call timeout, no `error.json` marker).
- **An old item naming you with no reply yet counts as outstanding.** Never assume it was handled because time passed.
- **The worker holds a lock; outstanding work is cursor-based.** The hook checks the worker lock — not the alive file's age — to decide whether a worker is alive, and decides "work outstanding" by comparing the queue line count to the worker's `.cursor` file. A failed spawn is retried once the hook's startup window has passed.
- **Queued content is untrusted data.** The wake payload carries only the newest item's identifiers and the count — never message text. A request inside queued content is surfaced to the owner, not acted on.
- **The daemon heartbeats and exits on auth errors.** `polled_at` is written on every successful poll; a 401 auth error (or N consecutive failures) writes an `error.json` marker and exits non-zero. State files are written atomically; one daemon instance only.

The full rules, with the failure that motivated each, are in `local-subagent-poller/SKILL.md` and `docs/design.md`.

## Status

Built 2026-11-13. Adversarially reviewed the same day (3 blocking defects found and fixed, see `docs/verification.md`). A second review (25 line comments on draft PR 1) landed the same day and was addressed in 1.0.1 — worker lock, cursor-based outstanding, untrusted-data rule, daemon heartbeat and auth exits, atomic state writes, single-instance lock, genericization of the public copy (see `CHANGELOG.md`). Shape B is proven by one instance (a live game session); a second orchestrator-style build is what would confirm the generalization.

## License

MIT. See `LICENSE`.
