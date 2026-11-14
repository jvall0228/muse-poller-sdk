# Subagent Poller SDK — local copy

Warm subagents plus plain script pollers, for seconds-fast replies to live events — when hooks and crons are too slow. A skill kit (prompt-driven, no installable library) for scaffolding pollers: an agent reads the skill, copies the templates, writes a small source adapter and fills in the hook and brief placeholders, and gets a working poller. The local copies keep the real values (paths, channel/bot/guild IDs); the public SDK repo sanitizes them.

## Two shapes, one core

Both shapes share one core: the queue protocol, the worker lock, the alive file and the worker and daemon stop files, the daemon heartbeat, and the rate-limit rules, defined in [`docs/design.md`](docs/design.md).

| Shape | When | How | Cost |
|---|---|---|---|
| **A — two-tier poller** | Work arrives in bursts with quiet gaps | Daemon polls the source and appends to a queue; a hook hands off to main when new work exists; main wakes the poller's side chat agent, which acts and exits after 10 min quiet | Zero tokens while idle; the first reply after quiet pays a cold start (~4.5 min, fleet-queue Nov 13; ~5.3 min end to end for the side-chat-agent shape, Nov 14) |
| **B — orchestrator** | A session is continuously live | A router polls the source, classifies each event, and dispatches to N slice-worker queues; each slice worker stays warm and owns one slice | A small liveness trickle per worker; replies land in seconds, always |

## Requirements

- **Hook runtime.** `templates/hook-watch.sh` sources `$HATCH_HOOK_RUNTIME`, which provides `hook_state_get` / `hook_state_set` (persistent per-hook JSON state), `silent <reason> <payload>` (end the poll quietly), and `wake <reason> <payload>` (spawn the worker). The hook is registered with `hooks.add` (60s poll, prompt from `templates/hook-prompt.md`) and tested with `hooks.dry_run` / `hooks.run`.
- **bash, `jq` and `flock(1)`.** The hook, `lock-holder.sh` and `rotate-queue.sh` are bash; the hook uses `jq`. `flock(1)` (util-linux) is needed for the worker lock, queue rotation, the hook's shared read of `queue.lock`, and the TS daemon's queue appends (it spawns `flock`). The watchdog script (`daemon-watchdog.sh`) additionally needs `pgrep(1)`; it parses `polled_at` in `jq`, so GNU `date` is not required. The watchdog worker detaches a restarted daemon with a small `python3` wrapper rather than `setsid(1)`.
- **Python 3.10+ or bun.** `daemon.py` uses the standard library only. `daemon.ts` needs bun. Pick by source: Python/CLI sources use `daemon.py`; REST sources with per-channel cursors suit `daemon.ts`.
- **Shape B needs no hook runtime.** Router and slice workers are subagents appending to queue files (under `flock`, see the briefs).
- **Start location (this environment).** Start daemons from agent context, never systemd: the egress proxy credential rotates per tool call, so a systemd service can never hold a current credential (proven Nov 13).

## Quick start

1. Read [`SKILL.md`](SKILL.md) (or load it as a skill) and pick the shape: intermittent work is Shape A, a continuous session is Shape B.
2. Copy the templates the SKILL lists for that shape, write the source adapter, edit the config, fill the hook and brief placeholders. The example configs are worked from the production pollers (JSON: fleet-queue, 60s; TS: Discord mentions, 10s).
3. Shape A: register the hook, start the daemon (`python3 daemon.py --config poller.config.json` or `bun daemon.ts --config poller.config.json`), wait for its baseline log event, then post a canary and measure post-to-reply.
4. To operate a built poller, read [`../local-subagent-poller-usage/SKILL.md`](../local-subagent-poller-usage/SKILL.md).

Measured latencies are in the SKILL; the rules and the failure behind each are in [`docs/design.md`](docs/design.md).

## Running the checks

The SDK repo's checks (`tests/daemon`, `tests/hook/run.sh`, `scripts/check-leaks.sh`, CI) run there, not here. Locally, verify a skill change with:

```
python3 -m json.tool local-subagent-poller/templates/poller.config.example.json
python3 -m json.tool local-subagent-poller/templates/poller.config.example.ts.json
python3 local-subagent-poller/templates/daemon.py --config <bad-config>; echo $?  # expect 2
diff -r local-subagent-poller ~/workspace/custom-skills/local-subagent-poller  # both copies identical
grep -rn '2[x] the poll interval\|example[-]poller\|<hooks[-]dir>' local-subagent-poller/SKILL.md local-subagent-poller/docs/ local-subagent-poller/references/  # expect no hits
```

## Layout

```
local-subagent-poller/          The SDK skill (scaffolder's skill)
  SKILL.md                      The skill: two shapes, the pieces, the workflow, the rules
  README.md                     This file: requirements, quick start, checks
  docs/
    design.md                   The design: why the shapes exist, the rules and what motivated each
    decisions.md                The decisions and their rationale
    review-guide.md             For reviewers: what to check, the known gaps, the open questions
    verification.md             How it was verified, what was found, what is still unproven
  templates/
    daemon.py                   Tier-1 daemon module (Python)
    daemon.ts                   Tier-1 daemon module (bun/TS)
    example_http_adapter.py     Example source adapter (Python)
    example-http-adapter.ts     Example source adapter (TS)
    poller.config.example.json  Example daemon config (Python, fleet-queue values)
    poller.config.example.ts.json  Example daemon config (TS, Discord-mentions values)
    tsconfig.json               Strict typecheck config for the TS daemon
    lock-holder.sh              Worker lock: take / release / status
    rotate-queue.sh             Archive a consumed queue, reset the cursor
    hook-watch.sh               Wake-hook script template (Shape A)
    hook-prompt.md              Wake-time spawner instruction template (Shape A)
    worker-brief.md             Active-worker brief template (Shape A)
    router-brief.md             Router brief template (Shape B)
    slice-worker-brief.md       Slice-worker brief template (Shape B)
    daemon-watchdog.sh          Daemon-supervision hook script (one hook, all daemons)
    watchdog-worker-brief.md    Watchdog worker brief
    daemon-registry.example.json  Watchdog registry example
  references/
    instances.md                The three live implementations the templates were extracted from

local-subagent-poller-usage/    The operator's skill: run a built poller
  SKILL.md                      Start, health-check, stop/resume, troubleshoot
```

## Status

Built 2026-11-13. Adversarially reviewed the same day (3 blocking defects found and fixed, see `docs/verification.md`). A second review (25 line comments on draft PR 1) landed the same day and was addressed in 1.0.1 — worker lock, cursor-based outstanding, untrusted-data rule, daemon heartbeat and auth exits, atomic state writes, single-instance lock, genericization of the public copy (see the SDK `CHANGELOG.md`). 1.1.0 turned the daemons into tested modules with source adapters and a config file, and added the lock and rotation scripts. 1.2.0 added the watchdog supervision template and transparency at the resolve gate. 1.2.1 split the worker and daemon stop files (ADR-17) and made the side chat agent the worker shape (ADR-18): the hook hands off to main, main wakes the poller's side chat agent, and the brief lives in the chat. Shape B is proven by one instance (Varisia live play); a second orchestrator-style build is what would confirm the generalization. The Varisia confirmed chain (Shape A daemon + hook + side chat agent as orchestrator) is configured, not yet live.

## Installation

No package manager, registry, or install command — installation is copying the directory.

- The copy that runs lives at `~/workspace/skills/local-subagent-poller/` — the compiled wisp binary discovers skills from `~/workspace/skills/` only.
- Mirror it to `~/workspace/custom-skills/local-subagent-poller/` and keep the two copies byte-identical (`diff -rq` after any edit).
- Each copy must contain `SKILL.md` (native format, no frontmatter) + `skill.yaml`. No `wisp.yaml` — this is a prompt-only skill with no CLI entrypoint, so there is no `wisp local-subagent-poller` command.
- This repo is the upstream copy. The harness loads the local `~/workspace/skills/` copy, not this one — after changing anything here, copy the directory to `~/workspace/skills/local-subagent-poller/` and mirror it to `~/workspace/custom-skills/local-subagent-poller/` (keep the two copies byte-identical) so the change takes effect.
