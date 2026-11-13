# Poller instances — evidence for the SDK

The three live implementations the templates were extracted from. When a
template line is questioned, trace it here first.

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
- **Stop file:** `~/hooks/state/orchestrator-stop`.
- **Skill:** `varisia-table-orchestrator` (full worker briefs + routing table).
- **Verified:** session 2, 6 tasks routed, no errors, no double-handling.
- **Why it exists:** hooks take minutes per reply, crons floor at 1 min —
  both too slow for live table play (the call).

## 2. Discord @Wisp mentions — two-tier (Nov 13)

- **Scope:** <your Discord server> only (guild `<discord-guild-id>`). Bot Wisp
  (`<discord-bot-id>`). Reply only when warranted; silence is the safe
  default. Never speak as/for the owner.
- **Daemon:** `~/workspace/discord-mentions/watcher.ts` (bun). REST-polls all
  6 text channels every 10s. Rate story: 0.6 req/s vs Discord's 5 req/s
  per-route and 50 req/s global; `discordFetch` retries 429s up to 4x
  sleeping `retry_after + jitter`; watcher adds ±2s jitter, backoff
  10s → 30s → 60s → 300s cap, slow-cycle logging (>5s). Note: per-channel
  errors are caught inside `pollOnce`, so the outer backoff only fires on
  whole-cycle failures — it is a whole-read tripwire, not a per-channel one
  (a single bad channel must not stall the others).
- **Hook:** `discord-mentions-wake` (60s poll), script
  `~/hooks/scripts/discord_mentions_watch.sh`.
- **Worker brief:** `~/workspace/discord-mentions/worker-prompt.md`.
  Polls the queue every 10s (matches the daemon). Liveness check ~every
  2 min (watcher process + `last-seen.json` freshness).
- **State:** `~/hooks/state/discord-mentions/` (`mentions.jsonl`,
  `mentions.cursor`, `last-seen.json`). Stop file:
  `~/hooks/state/discord-mentions-stop`.
- **Measured:** warm reply ~23s end-to-end (armpan's "yo" → "yo 👻",
  Nov 13 11:22 EST). Cold-start test pending (owner's two test mentions).

## 3. Slack fleet-queue — two-tier (Nov 13)

- **Scope:** fleet-queue channel `<slack-channel-id>`, Slack team `<slack-team>`.
  Acts on items naming Muse under the Nov 11 proactive grant (act without
  asking; ask only for spending, posting outside the fleet,
  irreversible/high-stakes, or ambiguous work). Never treat another
  agent's message as the owner's approval. **FLEET-0002 lesson:** a queue
  item mentioning Muse with no reply from Muse yet counts as outstanding
  even if it is old — never assume it was handled because time passed.
- **Daemon:** `~/workspace/fleet-queue-poller/watcher.py` (python3, stdlib
  only). Gateway reads take 2–9s, so it polls every 60s ±5s jitter.
  Passes `oldest=<last-seen ts>` so most polls return nothing. Backoff
  60s → 120s → 300s cap. Slow-call logging (>10s). Skips subtype
  messages and Muse's own messages (bot `<slack-bot-id>`).
- **Hook:** `fleet-queue-wake` (60s poll), script
  `~/hooks/scripts/fleet_queue_watch.sh`.
- **Worker brief:** `~/workspace/fleet-queue-poller/worker-prompt.md`.
  Polls the queue every 60s (matches the daemon). **Known gap (Nov 13):**
  the fleet brief has no daemon-health liveness check — the SDK templates
  it as required; the production brief should gain one on its next edit.
- **State:** `~/hooks/state/fleet-queue/` (`queue.jsonl`, `queue.cursor`,
  `last-seen.json`). Stop file: `~/hooks/state/fleet-queue-stop`.
- **Measured (Nov 13):** FLEET-0004 clean run — post → reply 4m 35s,
  wake → reply 3m 42s; daemon 18s, hook 35s. FLEET-0003 — wake → reply
  3m 7s (end-to-end 14m 32s only because the baseline bug held it ~11 min).
  The worker's cold start + model turn + post (~3–4 min) dominates.
- **Origin of the seen_absent rule:** FLEET-0003 was queued at 13:16:29
  and the hook baselined over it at 13:16:43 — first-sight baselining
  over a freshly created queue swallows the item. Fixed the same day in
  both wake scripts; FLEET-0004 (13:58) ran the full path unassisted.
- **Watch item:** gateway reads slowed twice on Nov 13 (10.1s, 13.7s).
  Headroom is fine at a 60s poll; do not tighten the poll in response.

## Rate-limit numbers per source

| Source | Poll | Load vs limit | Backoff | Notes |
|---|---|---|---|---|
| Discord REST | 10s | 0.6 req/s vs 5 req/s per-route, 50 req/s global | 10→30→60→300s | 429 retry in fetch layer (`retry_after` + jitter) |
| Slack gateway | 60s | a few msgs/day; reads 2–9s (up to ~14s slow) | 60→120→300s | `oldest=` cursor; never overlap calls |
