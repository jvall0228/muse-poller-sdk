# Subagent Poller SDK

Warm subagents plus plain script pollers, for seconds-fast replies to live events — when hooks and crons are too slow. A skill kit (prompt-driven, no installable library) for scaffolding pollers: an agent reads the skill, copies the templates, writes a small source adapter and fills in the hook and brief placeholders, and gets a working poller.

## The problem

Some work needs a reply in seconds when an external event happens: a player acts in a live game, a message lands in a queue, a device changes state. The scheduled mechanisms idle cheap but wake slow — hooks idle at zero tokens but take minutes to land a wake; crons poll at most once a minute. When seconds matter, the answer is to keep the agents warm and let dumb scripts do the watching.

## Two shapes, one core

Both shapes share one core: the queue protocol, the worker lock, the alive file and the worker and daemon stop files, the daemon heartbeat, and the rate-limit rules, defined in [`docs/design.md`](docs/design.md).

| Shape | When | How | Cost |
|---|---|---|---|
| **A — two-tier poller** | Work arrives in bursts with quiet gaps | Daemon polls the source and appends to a queue; a hook wakes a worker only when new work exists; the worker acts and exits after 10 min quiet | Zero tokens while idle; the first reply after quiet pays a cold start |
| **B — orchestrator** | A session is continuously live | A router polls the source, classifies each event, and dispatches to N slice-worker queues; each slice worker stays warm and owns one slice | A small liveness trickle per worker; replies land in seconds, always |

## Requirements

Shape A depends on a specific hook runtime, the one this SDK was extracted from. On another runtime you must supply the equivalent of each piece.

- **Hook runtime.** `templates/hook-watch.sh` sources `$HATCH_HOOK_RUNTIME`, which provides `hook_state_get` / `hook_state_set` (persistent per-hook JSON state), `silent <reason> <payload>` (end the poll quietly), and `wake <reason> <payload>` (spawn the worker). The hook is registered with `hooks.add` (60s poll, prompt from `templates/hook-prompt.md`) and tested with `hooks.dry_run` / `hooks.run`. Elsewhere, supply: a per-hook state store, a silent outcome, a wake outcome, and a way to register a 60s poll with a prompt.
- **bash, `jq` and `flock(1)`.** The hook, `lock-holder.sh` and `rotate-queue.sh` are bash; the hook uses `jq`. `flock(1)` (util-linux) is needed for the worker lock, queue rotation, the hook's shared read of `queue.lock`, and the TS daemon's queue appends (it spawns `flock`). It is not installed on macOS by default; install it separately. Bash 3.2+ works. The watchdog script (`daemon-watchdog.sh`) additionally needs `pgrep(1)`; it parses `polled_at` in `jq`, so GNU `date` is not required. `jq` and `pgrep` are checked at startup and a missing one ends the poll silently with the reason. macOS ships `pgrep` (and BSD `date`, which the watchdog does not use) but not `flock`; `jq` must be installed separately. The watchdog worker detaches a restarted daemon with a small `python3` wrapper rather than `setsid(1)`, which stock macOS lacks, so `python3` is needed where the worker runs.
- **Python 3.10+ or bun.** `daemon.py` uses the standard library only. `daemon.ts` needs bun. Pick by source: Python/CLI sources use `daemon.py`; REST sources with per-channel cursors suit `daemon.ts`.
- **Shape B needs no hook runtime.** Router and slice workers are subagents appending to queue files (under `flock`, see the briefs).

## Quick start

1. Read [`local-subagent-poller/SKILL.md`](local-subagent-poller/SKILL.md) (or load it as a skill) and pick the shape: intermittent work is Shape A, a continuous session is Shape B.
2. Copy the templates the SKILL lists for that shape, write the source adapter, edit the config, fill the hook and brief placeholders.
3. Shape A: register the hook, start the daemon (`python3 daemon.py --config poller.config.json` or `bun daemon.ts --config poller.config.json`), wait for its baseline log line, then post a canary and measure post-to-reply.
4. To operate a built poller, read [`local-subagent-poller-usage/SKILL.md`](local-subagent-poller-usage/SKILL.md).

Measured latencies are in the SKILL; the rules and the failure behind each are in [`docs/design.md`](docs/design.md).

## Running the checks

From the repository root (CI runs the same commands, see `.github/workflows/ci.yml`):

```
shellcheck -x local-subagent-poller/templates/*.sh tests/hook/*.sh scripts/*.sh
ruff check .
python3 -m pytest tests/daemon
bun install && bunx tsc --noEmit -p local-subagent-poller/templates/tsconfig.json
bun test tests/daemon
tests/hook/run.sh
scripts/check-leaks.sh
```

`scripts/check-leaks.sh` fails on home paths, email addresses, chat-style IDs and ticket keys. It also reads extra terms, one per line, from an untracked `.leak-terms` file.

## Layout

```
local-subagent-poller/          The SDK skill (scaffolder's skill)
  SKILL.md                      The skill: two shapes, the pieces, the workflow, the rules
  templates/
    daemon.py                   Tier-1 daemon module (Python)
    daemon.ts                   Tier-1 daemon module (bun/TS)
    example_http_adapter.py     Example source adapter (Python)
    example-http-adapter.ts     Example source adapter (TS)
    poller.config.example.json  Example daemon config (Python)
    poller.config.example.ts.json  Example daemon config (TS)
    tsconfig.json               Strict typecheck config for the TS daemon
    lock-holder.sh              Worker lock: take / release / status
    rotate-queue.sh             Archive a consumed queue, reset the cursor
    hook-watch.sh               Wake-hook script template (Shape A)
    hook-prompt.md              Wake-time spawner instruction template (Shape A)
    worker-brief.md             Active-worker brief template (Shape A)
    router-brief.md             Router brief template (Shape B)
    slice-worker-brief.md       Slice-worker brief template (Shape B)
  references/
    instances.md                The three live implementations the templates were extracted from

local-subagent-poller-usage/    The operator's skill: run a built poller
  SKILL.md                      Start, health-check, stop/resume, troubleshoot

tests/
  daemon/                       pytest + bun tests for the daemons
  hook/run.sh                   Plain-bash tests for the hook, lock holder and rotation

scripts/
  check-leaks.sh                Fails on deployment-specific strings in tracked files

docs/
  design.md                     The design: why the shapes exist, the rules and what motivated each
  verification.md               How it was verified: adversarial review, template checks, live tests
  review-guide.md               For reviewers: what to check, the known gaps, the open questions
  decisions.md                  The decisions and their rationale
```

## Status

Built 2026-11-13. Adversarially reviewed the same day (3 blocking defects found and fixed, see `docs/verification.md`). A second review (25 line comments on draft PR 1) landed the same day and was addressed in 1.0.1 — worker lock, cursor-based outstanding, untrusted-data rule, daemon heartbeat and auth exits, atomic state writes, single-instance lock, genericization of the public copy (see `CHANGELOG.md`). 1.1.0 turned the daemons into tested modules with source adapters and a config file, and added the lock and rotation scripts (see `CHANGELOG.md`). Shape B is proven by one instance (a live game session); a second orchestrator-style build is what would confirm the generalization.

## License

MIT. See `LICENSE`.
