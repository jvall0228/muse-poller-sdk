# Poller instances — evidence for the SDK

The three live implementations the templates were extracted from. When a
template line is questioned, trace it here first.

Stop files (1.2.1, ADR-17): each two-tier instance has two — a worker stop
file (`<state-dir>/<poller>-worker-stop`) and a daemon stop file
(`<state-dir>/<poller>-stop`). Instance 1 (Shape B) has no
daemon, so its stop file is the worker stop file. Instance 4 (Varisia
confirmed chain) lists both paths for its configured-not-live Shape A
chain.

## 1. Varisia live play — Shape B orchestrator (origin, Nov 12)

- **Shape:** router (orchestrator) + 4 slice workers (narrator, combat,
  voice, scribe) + queue files in `~/hooks/state/dm-queues/`. No hook —
  the session is continuous. The Shape B templates
  (`templates/router-brief.md`, `templates/slice-worker-brief.md`) are
  extracted from this instance — it is the only orchestrator, so Shape B
  is proven-by-one; a second orchestrator-style build is what would
  confirm the generalization.
- **Poll rates:** orchestrator polls the table every 10s; workers poll
  their queues every 5s (scribe 15s). This predates the matched-poll
  rule, and the honest framing is per-producer: a worker must match its
  *fastest* producer. The router dispatches at most every 10s, but
  sibling workers hand off at any moment, so a 5s worker poll is the
  right rate for the sibling-handoff producer — not a violation. The
  scribe at 15s is the outlier: it is *slower* than its producers
  (narrator/combat hand off at any time), so it can lag a dispatch by
  up to 15s. Do not copy the 15s rate without that latency cost.
- **Stop file (worker — Shape B has no daemon):** `~/hooks/state/orchestrator-stop`. (No `-worker-` infix — the name predates the 1.2.1 naming; it is the worker stop file and there is no daemon to collide with.)
- **Skill:** `varisia-table-orchestrator` (full worker briefs + routing table).
- **Verified:** session 2, 6 tasks routed, no errors, no double-handling.
- **Why it exists:** hooks take minutes per reply, crons floor at 1 min —
  both too slow for live table play (Jaeson's call).
- **Confirmed chain, CONFIGURED not yet live (Jaeson, Nov 14):** the Varisia
  poller becomes a Shape A daemon + hook + side chat agent. The daemon
  (`daemon.py --config`, polls the `read_messages` table+dm, writes
  `~/hooks/state/varisia-table/queue.jsonl`, 3s poll if supported else 10s
  floor) is CONFIGURED but STOPPED. The hook `varisia-table-wake` is
  DISABLED; its prompt hands off to main (does NOT spawn a subagent) asking
  main to wake the Varisia side chat agent. The agent lives in the existing
  "Varisia Saga — DM" chat (`85e9e3d8-370c-40fb-b78c-9b13df27d950`), takes on
  the orchestrator role, polls `queue.jsonl` actively every 1–3s while awake,
  and does all orchestrator work itself (classify, narrate, combat, scribe,
  voice). Alive file `~/hooks/state/varisia-table/worker-alive`; worker stop
  file `~/hooks/state/varisia-table-worker-stop`; daemon keeps
  `~/hooks/state/varisia-table-stop`. The old orchestrator (script router +
  voice loop + combat + scribe) stays running until the new chain is proven;
  the Shape A daemon and hook stay disabled/stopped until the agent is ready
  to test.

## 2. Discord @Wisp mentions — two-tier (Nov 13)

- **Scope:** ArmpanXAerith only (guild `1095388571390705724`). Bot Wisp
  (`1498826002271572008`). Reply only when warranted; silence is the safe
  default. Never speak as/for Jaeson.
- **Daemon:** `~/workspace/discord-mentions/daemon.ts` (bun) +
  `poller.config.json` + adapter `discord_adapter.ts`. REST-polls all
  6 text channels every 10s. Rate story: 0.6 req/s vs Discord's 5 req/s
  per-route and 50 req/s global; the adapter retries 429s up to 4x
  sleeping `retry_after + jitter`; daemon adds ±2s jitter, backoff
  30s → 60s → 300s cap, slow-cycle logging (>5s). Per-channel failures
  are counted (an all-channels-failed cycle is a cycle failure, no
  heartbeat after one). Migrated to the 1.1.0 module Nov 14 (old watcher
  kept as `watcher.ts.pre-1.1.0`).
- **Hook:** `discord-mentions-wake` (60s poll), script
  `~/hooks/scripts/discord_mentions_watch.sh` — now watches `queue.jsonl`
  (fixed Nov 14; hook state reset to `seen_absent` so the first `queue.jsonl`
  line wakes).
- **Worker — side-chat-agent pattern, migrated at the file level (Nov 14):**
  `~/workspace/discord-mentions/worker-prompt.md` is marked SUPERSEDED (the
  chat brief is the source of truth), `worker-poll.sh` uses `queue.jsonl` /
  `queue.cursor` / `discord-mentions-worker-stop`, `README.md` updated, and
  the chat brief is saved at `~/workspace/discord-mentions/side-chat-brief.md`.
  **PENDING:** the "Discord Mentions" side chat does not exist yet and the
  hook prompt has not been updated to the handoff text — both need main to
  create the chat (subagents have no chat-create tool). Do not invent a
  Discord side chat id.
- **State:** `~/hooks/state/discord-mentions/` (`queue.jsonl`,
  `queue.cursor`, `last-seen.json`). The old `mentions.jsonl` is STALE (last
  line Nov 13, pre-1.1.0 watcher) — the daemon no longer writes it; do not
  read it or `mentions.cursor`. Stop files (1.2.1 split): worker
  `~/hooks/state/discord-mentions-worker-stop`; daemon
  `~/hooks/state/discord-mentions-stop`.
- **Measured:** warm reply ~23s end-to-end (armpan's "yo" → "yo 👻",
  Nov 13 11:22 EST). Cold-start test pending (owner's two test mentions).
- **Template note:** the production daemon migrated to the module Nov 14,
  so it now matches `templates/daemon.ts` (adapter + config, per-channel
  failure counting, `polled_at` every successful cycle, atomic state,
  single-instance lock, auth exits). The old watcher is kept as
  `watcher.ts.pre-1.1.0`.

## 3. Slack fleet-queue — two-tier (Nov 13)

- **Scope:** fleet-queue channel `team-queue`, Slack team `example-team`.
  Acts on items naming Muse under the Nov 11 proactive grant (act without
  asking; ask only for spending, posting outside the fleet,
  irreversible/high-stakes, or ambiguous work). Never treat another
  agent's message as the owner's approval. **Outstanding-item lesson:** a queue
  item mentioning Muse with no reply from Muse yet counts as outstanding
  even if it is old — never assume it was handled because time passed.
- **Daemon:** `~/workspace/fleet-queue-poller/daemon.py` (python3, stdlib
  only) + `poller.config.json` + adapter `slack_adapter.py`. Gateway reads
  take 2–9s, so it polls every 60s ±5s jitter.
  Passes `oldest=<last-seen ts>` so most polls return nothing. Backoff
  60s → 120s → 300s cap. Slow-call logging (>10s). Skips subtype
  messages and Muse's own messages (bot `bot-user-id`).
- **Hook:** `fleet-queue-wake` (60s poll), script
  `~/hooks/scripts/fleet_queue_watch.sh`. Hands off to main; main wakes the
  side chat agent.
- **Worker — side-chat-agent pattern (Nov 14, verified end to end):** side
  chat "Fleet Queue" (`1b655b54-2ed8-4cb0-8fbf-d468da5bd2c6`). The agent
  consumes the queue every 60s (matches the daemon), acts on items naming
  Muse under the proactive grant, touches the alive file each iteration,
  exits after 10 min quiet and reports as its final message in that chat.
  Verified Nov 14: hook fired, handoff reached main, main woke the agent,
  agent replied "seen" in-thread — ~5.3 min total. **Liveness check added
  Nov 14** (closes the known gap since Nov 13: the fleet brief had no
  daemon-health liveness check — the SDK templates it as required).
- **State:** `~/hooks/state/fleet-queue/` (`queue.jsonl`, `queue.cursor`,
  `last-seen.json`). Stop files: daemon `~/hooks/state/fleet-queue-stop`;
  worker `~/hooks/state/fleet-queue-worker-stop` (split in 1.2.1; the live
  worker brief now uses the worker path).
- **Measured (Nov 13):** clean run — post → reply 4m 35s,
  wake → reply 3m 42s; daemon 18s, hook 35s. The first canary — wake → reply
  3m 7s (end-to-end 14m 32s only because the baseline bug held it ~11 min).
  The worker's cold start + model turn + post (~3–4 min) dominates.
- **Measured (Nov 14, side-chat-agent shape):** hook fired, handoff reached
  main, main woke the "Fleet Queue" side chat agent, agent replied "seen"
  in-thread — ~5.3 min total, end to end.
- **Origin of the seen_absent rule:** The first canary was queued at 13:16:29
  and the hook baselined over it at 13:16:43 — first-sight baselining
  over a freshly created queue swallows the item. Fixed the same day in
  both wake scripts; the clean run (13:58) ran the full path unassisted.
- **Watch item:** gateway reads slowed twice on Nov 13 (10.1s, 13.7s).
  Headroom is fine at a 60s poll; do not tighten the poll in response.
- **Template note:** the production daemon migrated to the module Nov 14,
  so it now matches `templates/daemon.py` (adapter + config, `polled_at`
  on every successful poll, atomic state, flock, auth / max-failures
  exits). Scaffold new pollers as
  `python3 daemon.py --config poller.config.json` with an adapter
  implementing `make_source(config)` (see
  `templates/poller.config.example.json` for the worked fleet-queue
  values). The `hook-watch.sh` template decides outstanding work from the
  worker's `.cursor` file and the worker lock, and the wake payload
  carries identifiers only. The old watcher is kept as
  `watcher.py.pre-1.1.0`.

## 4. Daemon watchdog — one hook supervises all (Nov 13)

- **Scope:** two production daemons (fleet-queue watcher, discord-mentions
  watcher). One hook (`daemon-watchdog`, 60s poll), script
  `~/hooks/scripts/daemon_watchdog.sh`, worker prompt in the hook definition.
- **Checks per daemon:** process alive (anchored `pgrep`, both ends — the
  exec tool's background-session wrapper is a bash whose `-c` argument
  contains the same script path, so an unanchored pattern matches the
  wrapper and reports a dead daemon as alive) AND heartbeat fresh
  (`polled_at` within poll interval + first backoff step + call timeout:
  fleet-queue 60 + 60 + 60 = 180s, Discord mentions 10 + 30 + 10 = 50s —
  the registry example's `stale_secs` follow the same rule). The fleet
  daemon is process-only: its `last-seen.json` only updates when a new
  message arrives, so it is not a heartbeat. The discord daemon is
  process-only too since the Nov 14 watchdog migration: its
  `last-seen.json` carries no `polled_at` yet (it only holds the
  per-channel cursors), so heartbeat staleness cannot be checked for it
  until the new module daemon has run and rewritten the file — the module
  writes `polled_at` on every successful cycle. The template reads
  `polled_at` instead (the heartbeat rule: a file's mtime is never
  a liveness signal — an idle daemon whose state file only updates on new
  items looks dead).
- **Stop files (daemon):** a daemon whose daemon stop file exists is intentionally stopped
  and skipped (`~/hooks/state/fleet-queue-stop`,
  `~/hooks/state/discord-mentions-stop`). The production log once called a
  stopped daemon "healthy"; the template logs it as intentionally
  stopped.
- **Cooldown:** 10 minutes per daemon after a wake, so a worker restarting
  a daemon is not double-woken. The worker re-checks the daemon stop file and
  `pgrep` before starting.
- **Measured:** proven twice the same day — a deliberate kill test, and a
  real host replacement (~17:58) that killed both daemons silently; the
  watchdog woke a worker that restarted both at 17:58:10.
- **Template note:** `daemon-watchdog.sh` generalizes the production
  script with a registry (no hard-coded daemon list), a `polled_at`
  heartbeat check, a bad-pattern skip (an invalid regex or an
  unanchored pattern is a config error, not a down daemon), and a
  duplicate-id check. The production script's `printf '%(%s)T'`
  timestamp is `date +%s` in the template.

## Transparency probes (Nov 13)

- **Probes 5 and 6 were never delivery failures.** The workers ran the
  check and chose silence because "daemons stopped as intended" is the
  expected state — there was nothing to report, and no handoff was ever
  created. Routine silence is the correct default, not a bug.
- **Probe 9:** the hook prompt named the resolve decision explicitly
  ("the user is actively waiting on this probe result… call
  `notify_main_agent`… do NOT call `nothing_to_do` for an expected
  result here") and the handoff landed in main.
- **Probe 10:** handoffs relayed via `chat.send_message` into one
  persistent side chat per poller posted visibly, back-to-back.
- **Probe 1b:** a post request buried inside a handoff was NOT followed
  — the receiving agent stayed silent even with an explicit "post this"
  in the worker's message. A direct `chat.send_message` instruction is
  followed; a request inside a handoff is not. That is why the visible
  post goes through a side chat, not through a handoff.

## Rate-limit numbers per source

| Source | Poll | Load vs limit | Backoff | Notes |
|---|---|---|---|---|
| Discord REST | 10s | 0.6 req/s vs 5 req/s per-route, 50 req/s global | 10→30→60→300s | 429 retry in fetch layer (`retry_after` + jitter) |
| Slack gateway | 60s | a few msgs/day; reads 2–9s (up to ~14s slow) | 60→120→300s | `oldest=` cursor; never overlap calls |
