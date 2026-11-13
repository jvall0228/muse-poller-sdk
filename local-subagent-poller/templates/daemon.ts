#!/usr/bin/env bun
// {{DAEMON_NAME}} (tier 1 daemon, bun/TS) — TEMPLATE.
// Extracted from the production Discord mention watcher (Nov 13 2026).
// Use this template for a Discord-like source (REST polling, per-channel
// cursors, a fetch layer with 429 retry). For a Python/CLI source use
// templates/daemon.py instead. Copy into the new poller's directory and
// fill in the {{...}} placeholders. Keep the structure verbatim — the
// baseline, per-channel cursor, no-overlap, and slow-cycle rules are
// load-bearing.
//
// Fill in ({{POLL_MS}} is a bare integer in milliseconds, e.g. 10000):
//   {{DAEMON_NAME}}       — e.g. "Discord mention watcher"
//   {{SOURCE_DESCRIPTION}}— one line: what it polls, e.g. "<your Discord server> only"
//   {{STATE_DIR_NAME}}    — state dir name under ~/hooks/state/
//   {{STOP_FILE_NAME}}    — stop file name under ~/hooks/state/
//   {{QUEUE_NAME}}        — queue file name, e.g. "mentions.jsonl"
//   {{POLL_MS}}           — poll interval in ms, e.g. 10000
//   {{POLL_JITTER_MS}}    — jitter on the sleep, e.g. 2000
//   {{BACKOFF_STEPS_MS}}  — e.g. [10000, 30000, 60000, 300000]. Cap, reset
//                           on success. The first failure sleeps
//                           BACKOFF_STEPS[0].
//   {{SLOW_CYCLE_MS}}     — slow-cycle threshold, e.g. 5000
//   {{CHANNELS}}          — the channel list (id + name), verified against
//                           the source
//   {{FETCH_IMPORT}}      — the fetch import, e.g.
//                           `import { discordFetch } from ".../lib/rest.ts"`
//   {{FETCH_CALL}}        — the fetch call (the `path` variable is in scope),
//                           e.g. `discordFetch(path, { as: "bot" })`
//   {{BOT_ID}}            — the bot's own id (never answer its own lines)
//   {{IS_NEW}}            — the per-message filter, e.g.
//                           `const mentionsWisp = (m.mentions || []).some((u) => u.id === BOT_ID); if (!mentionsWisp) continue;`
//   {{QUEUE_ITEM}}        — the queue line shape. Include every field the
//                           worker's decision rules need (who it is for,
//                           channel, author, timestamp) — a minimal shape
//                           forces the worker to re-fetch per item.
//   {{DRY_RUN_FLAG}}      — the dry-run argv check, e.g. `Bun.argv.includes("--dry-run")`
//   {{SOURCE_TYPE}}       — e.g. "Discord"
//
// Notes:
// - Per-channel errors are caught inside pollOnce, so the outer backoff
//   only fires on whole-cycle failures. That is the intended behavior:
//   one bad channel must not stall the others, and the backoff is a
//   whole-read tripwire, not a per-channel one.
// - Rate-limit retry lives in the fetch layer ({{FETCH_IMPORT}}), not here.
//   This loop only does failure backoff (minutes) and slow-cycle logging.
// - First sight of a channel baselines its high-water mark and queues
//   nothing. An empty first poll stays unbaselined for that channel.

{{FETCH_IMPORT}}
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from "fs";

const BOT_ID = "{{BOT_ID}}"; // never answer its own lines
const POLL_MS = {{POLL_MS}};
const POLL_JITTER_MS = {{POLL_JITTER_MS}};
// Backoff on consecutive failed cycles. Prevents hammering the source
// during an outage or auth break.
const BACKOFF_STEPS = {{BACKOFF_STEPS_MS}};
const STATE_DIR = `${process.env.HOME}/hooks/state/{{STATE_DIR_NAME}}`;
const QUEUE_FILE = `${STATE_DIR}/{{QUEUE_NAME}}`;
const LAST_SEEN_FILE = `${STATE_DIR}/last-seen.json`;
const STOP_FILE = `${process.env.HOME}/hooks/state/{{STOP_FILE_NAME}}`;

const CHANNELS: Array<{ id: string; name: string }> = {{CHANNELS}};

type LastSeen = Record<string, string>; // channelId -> newest message id seen

function loadLastSeen(): LastSeen {
  try {
    if (existsSync(LAST_SEEN_FILE)) return JSON.parse(readFileSync(LAST_SEEN_FILE, "utf8"));
  } catch {}
  return {};
}
function saveLastSeen(ls: LastSeen) {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(LAST_SEEN_FILE, JSON.stringify(ls, null, 2));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (s: string) => console.log(`[${new Date().toISOString()}] ${s}`);

async function pollOnce(lastSeen: LastSeen, dryRun: boolean): Promise<LastSeen> {
  const next: LastSeen = { ...lastSeen };
  for (const ch of CHANNELS) {
    try {
      const after = lastSeen[ch.id];
      const path = after
        ? `/channels/${ch.id}/messages?limit=25&after=${after}`
        : `/channels/${ch.id}/messages?limit=10`;
      const msgs = (await {{FETCH_CALL}}) as any[];
      if (!Array.isArray(msgs) || msgs.length === 0) continue;
      // Source returns newest-first; process oldest-first so the queue stays in order.
      const ordered = [...msgs].reverse();
      const newest = ordered[ordered.length - 1].id;
      if (!after && !dryRun) {
        // First sight of this channel: baseline only, queue nothing (no stale replies).
        next[ch.id] = newest;
        continue;
      }
      next[ch.id] = newest;
      for (const m of ordered) {
        if (m.author?.id === BOT_ID) continue; // never answer our own lines
        {{IS_NEW}}
        const task = {{QUEUE_ITEM}};
        if (dryRun) {
          log(`WOULD QUEUE #${ch.name} ${m.author?.username}: ${(m.content || "").slice(0, 100)}`);
        } else {
          mkdirSync(STATE_DIR, { recursive: true });
          appendFileSync(QUEUE_FILE, JSON.stringify(task) + "\n");
          log(`queued #${ch.name} ${m.author?.username}: ${(m.content || "").slice(0, 100)}`);
        }
      }
    } catch (e: any) {
      log(`#${ch.name} poll failed: ${e.message}`);
    }
  }
  return next;
}

async function main() {
  const dryRun = {{DRY_RUN_FLAG}};
  mkdirSync(STATE_DIR, { recursive: true });
  if (dryRun) {
    log("dry-run: one cycle, writing nothing");
    await pollOnce(loadLastSeen(), true);
    log("dry-run done");
    return;
  }
  log("{{DAEMON_NAME}} live — {{SOURCE_DESCRIPTION}}, polling every " +
    `${POLL_MS / 1000}s ±${POLL_JITTER_MS / 1000}s jitter (stop file: {{STOP_FILE_NAME}})`);
  let lastSeen = loadLastSeen();
  let consecutiveFailures = 0;
  while (true) {
    if (existsSync(STOP_FILE)) {
      log("stop file present — exiting");
      return;
    }
    const cycleStart = Date.now();
    try {
      lastSeen = await pollOnce(lastSeen, false);
      saveLastSeen(lastSeen);
      consecutiveFailures = 0;
    } catch (e: any) {
      consecutiveFailures++;
      log(`cycle error (${consecutiveFailures} in a row): ${e.message}`);
    }
    const cycleMs = Date.now() - cycleStart;
    if (cycleMs > {{SLOW_CYCLE_MS}}) log(`slow cycle: ${cycleMs}ms (retries likely — watch rate limits)`);
    // Jittered sleep, stretched by backoff after consecutive failures.
    const backoff = BACKOFF_STEPS[Math.min(Math.max(consecutiveFailures - 1, 0), BACKOFF_STEPS.length - 1)];
    const sleepMs = Math.max(POLL_MS, backoff) + (Math.random() * 2 - 1) * POLL_JITTER_MS;
    await sleep(Math.max(1000, sleepMs));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
