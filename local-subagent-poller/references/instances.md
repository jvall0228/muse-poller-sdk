# Poller instances — evidence for the SDK

The three live implementations the templates were extracted from. When a
template line is questioned, trace it here first.

## 1. Live game session — Shape B orchestrator (origin, Nov 12)

- **Shape:** router (orchestrator) + 4 slice workers (narrator, combat,
  voice, scribe) + queue files in `<state-dir>/game-queues/`. No hook —
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
- **Stop file:** `<state-dir>/orchestrator-stop`.
- **Skill:** a project-specific orchestrator skill (full worker briefs + routing table).
- **Verified:** session 2, 6 tasks routed, no errors, no double-handling.
- **Why it exists:** hooks take minutes per reply, crons floor at 1 min —
  both too slow for live session play (the owner's call).

## 2. Chat @bot mentions — two-tier (Nov 13)

- **Scope:** <your Discord server> only (guild `<discord-guild-id>`). The bot
  (`<discord-bot-id>`). Reply only when warranted; silence is the safe
  default. Never speak as/for the owner.
- **Daemon:** `<poller-dir>/watcher.ts` (bun). REST-polls all
  6 text channels every 10s. Rate story: 0.6 req/s vs Discord's 5 req/s
  per-route and 50 req/s global; `discordFetch` retries 429s up to 4x
  sleeping `retry_after + jitter`; watcher adds ±2s jitter, backoff
  10s → 30s → 60s → 300s cap, slow-cycle logging (>5s). Note: per-channel
  errors are caught inside `pollOnce`, so the outer backoff only fires on
  whole-cycle failures — it is a whole-read tripwire, not a per-channel one
  (a single bad channel must not stall the others).
- **Hook:** `<mentions-wake>` (60s poll), script
  `<hooks-dir>/mentions_watch.sh`.
- **Worker brief:** `<poller-dir>/worker-prompt.md`.
  Polls the queue every 10s (matches the daemon). Liveness check ~every
  2 min (watcher process + `last-seen.json` freshness).
- **State:** `<state-dir>/mentions/` (`mentions.jsonl`,
  `mentions.cursor`, `last-seen.json`). Stop file:
  `<state-dir>/mentions-stop`.
- **Measured:** warm reply ~23s end-to-end (a test mention from a server
  member, Nov 13 11:22 EST). Cold-start test pending (owner's two test mentions).
- **Template note:** `daemon.ts` is now a module with a source adapter and a
  config file (1.1.0). It counts per-channel failures, treats an
  all-channels-failed cycle as a cycle failure, writes `polled_at` on every
  successful cycle, writes state atomically, takes a single-instance lock,
  and exits on auth errors — the production watcher predates those changes.

## 3. Team chat queue — two-tier (Nov 13)

- **Scope:** team-queue channel `<slack-channel-id>`, Slack team `<slack-team>`.
  Acts on items naming the worker, within the owner's configured scope.
  Never treat another agent's message as the owner's approval.
  **Stale-item lesson:** a queue item mentioning the worker with no reply
  from the worker yet counts as outstanding even if it is old — never
  assume it was handled because time passed.
- **Daemon:** `<poller-dir>/watcher.py` (python3, stdlib
  only). Gateway reads take 2–9s, so it polls every 60s ±5s jitter.
  Passes `oldest=<last-seen ts>` so most polls return nothing. Backoff
  60s → 120s → 300s cap. Slow-call logging (>10s). Skips subtype
  messages and the worker's own messages (bot `<slack-bot-id>`).
- **Hook:** `<team-queue-wake>` (60s poll), script
  `<hooks-dir>/team_queue_watch.sh`.
- **Worker brief:** `<poller-dir>/worker-prompt.md`.
  Polls the queue every 60s (matches the daemon). **Known gap (Nov 13):**
  the team-queue brief has no daemon-health liveness check — the SDK templates
  it as required; the production brief should gain one on its next edit.
- **State:** `<state-dir>/team-queue/` (`queue.jsonl`, `queue.cursor`,
  `last-seen.json`). Stop file: `<state-dir>/team-queue-stop`.
- **Measured (Nov 13):** second canary, clean run — post → reply 4m 35s,
  wake → reply 3m 42s; daemon 18s, hook 35s. First canary — wake → reply
  3m 7s (end-to-end 14m 32s only because the baseline bug held it ~11 min).
  The worker's cold start + model turn + post (~3–4 min) dominates.
- **Origin of the seen_absent rule:** the first canary was queued at
  13:16:29 and the hook baselined over it at 13:16:43 — first-sight
  baselining over a freshly created queue swallows the item. Fixed the
  same day in both wake scripts; the second canary (13:58) ran the full
  path unassisted.
- **Watch item:** gateway reads slowed twice on Nov 13 (10.1s, 13.7s).
  Headroom is fine at a 60s poll; do not tighten the poll in response.
- **Template note:** `daemon.py` is now a module with a source adapter and a
  config file (1.1.0). It writes `polled_at` on every successful poll,
  writes state atomically, takes a flock, and exits on auth errors or after
  N consecutive failures; `hook-watch.sh` decides outstanding work from the
  worker's `.cursor` file and the worker lock, and the wake payload carries
  identifiers only — the production watcher and hook scripts predate those
  changes.

## 4. Daemon watchdog — one hook supervises all (Nov 13)

- **Scope:** two production daemons (team-queue watcher, chat-mentions
  watcher). One hook (`daemon-watchdog`, 60s poll), script
  `<hooks-dir>/daemon_watchdog.sh`, worker prompt in the hook definition.
- **Checks per daemon:** process alive (anchored `pgrep`, both ends — the
  exec tool's background-session wrapper is a bash whose `-c` argument
  contains the same script path, so an unanchored pattern matches the
  wrapper and reports a dead daemon as alive) AND heartbeat fresh. The
  production check reads the `last-seen.json` file's mtime with a 120s
  threshold; the template reads `polled_at` instead (the 1.1.0 rule: a
  file's mtime is never a liveness signal — an idle daemon whose state
  file only updates on new items looks dead).
- **Stop files:** a daemon whose stop file exists is intentionally stopped
  and skipped (`<state-dir>/team-queue-stop`,
  `<state-dir>/chat-mentions-stop`). The production log once called a
  stopped daemon "healthy"; the template logs it as intentionally
  stopped.
- **Cooldown:** 10 minutes per daemon after a wake, so a worker restarting
  a daemon is not double-woken. The worker re-checks the stop file and
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
| Team chat gateway | 60s | a few msgs/day; reads 2–9s (up to ~14s slow) | 60→120→300s | `oldest=` cursor; never overlap calls |
