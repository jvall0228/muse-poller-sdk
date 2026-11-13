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
//   {{SOURCE_DESCRIPTION}}— one line: what it polls, e.g. "<your server> only"
//   {{STATE_DIR_NAME}}    — state dir name under ~/hooks/state/
//   {{STOP_FILE_NAME}}    — stop file name under ~/hooks/state/
//   {{QUEUE_NAME}}        — queue file name, e.g. "mentions.jsonl"
//   {{POLL_MS}}           — poll interval in ms, e.g. 10000
//   {{POLL_JITTER_MS}}    — jitter on the sleep, e.g. 2000
//   {{BACKOFF_STEPS_MS}}  — e.g. [10000, 30000, 60000, 300000]. Cap, reset
//                           on success. The first failure sleeps
//                           BACKOFF_STEPS[0].
//   {{SLOW_CYCLE_MS}}     — slow-cycle threshold, e.g. 5000
//   {{MAX_FAILURES}}      — consecutive failed cycles before the daemon
//                           gives up and exits non-zero, e.g. 5. A 401 exits
//                           immediately, without waiting for this count. One
//                           channel failing this many cycles in a row while
//                           others succeed writes an error marker but does
//                           not exit.
//   {{CHANNELS}}          — the channel list (id + name), verified against
//                           the source
//   {{FETCH_IMPORT}}      — the fetch import, e.g.
//                           `import { discordFetch } from ".../lib/rest.ts"`
//   {{FETCH_CALL}}        — the fetch call (the `path` variable is in scope),
//                           e.g. `discordFetch(path, { as: "bot" })`
//   {{BOT_ID}}            — the bot's own id (never answer its own lines)
//   {{IS_NEW}}            — the per-message filter, e.g.
//                           `const mentionsBot = (m.mentions || []).some((u) => u.id === BOT_ID); if (!mentionsBot) continue;`
//   {{QUEUE_ITEM}}        — the queue line shape. Include every field the
//                           worker's decision rules need (who it is for,
//                           channel, author, timestamp) — a minimal shape
//                           forces the worker to re-fetch per item.
//   {{DRY_RUN_FLAG}}      — the dry-run argv check, e.g. `Bun.argv.includes("--dry-run")`
//   {{SOURCE_TYPE}}       — e.g. "Discord"
//
// Notes:
// - Per-channel errors are caught inside pollOnce so one bad channel does
//   not stall the others — but they are COUNTED, not swallowed. If every
//   channel fails in one cycle (e.g. a 401 on every read), that cycle
//   counts as a failure: the heartbeat is not written, and after
//   {{MAX_FAILURES}} such cycles in a row the daemon writes an error
//   marker and exits non-zero. A 401 (credential-wide) exits immediately;
//   an auth error on every channel in one cycle does too. A channel that
//   fails {{MAX_FAILURES}} cycles in a row while others succeed (often
//   missing access to that one channel) gets a channel-warning.json marker
//   naming it, and the daemon keeps running. This is deliberately NOT
//   error.json: error.json means the daemon gave up and must be restarted.
// - The fetch layer must attach the HTTP status to the errors it throws
//   (e.g. `Object.assign(new Error(msg), { status })`); isAuthError reads
//   `e.status`, never the message text.
// - Rate-limit retry lives in the fetch layer ({{FETCH_IMPORT}}), not here.
//   This loop only does failure backoff (minutes) and slow-cycle logging.
// - First sight of a channel baselines its high-water mark and queues
//   nothing. An empty first poll stays unbaselined for that channel.
// - Logs carry channel and message id only — never a username or message
//   text. The queue lines hold the content; the log is not the place for it.
//
// Credentials: read the source token from the environment or a secrets
// store — never hard-code it in the filled-in template and never commit
// it. Keep it out of logs and queue lines, and handle expiry explicitly:
// an expired or revoked credential raises an auth error (see isAuthError),
// and the daemon exits non-zero rather than retrying forever.
//
// Starting the daemon: a supervised service (systemd, launchd) is fine in
// normal environments. Only where network credentials are scoped to an
// agent's tool call (for example an egress-proxy credential that rotates per
// call) must the daemon be started from agent context (a tool call, a cron,
// or a hook), because a service cannot hold a current credential there. A
// long-running daemon keeps working on the credential it started with; in
// such environments, recovery after the host is replaced needs an
// agent-context mechanism.

{{FETCH_IMPORT}}
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync, renameSync, unlinkSync, openSync, closeSync, fsyncSync } from "node:fs";

const BOT_ID = "{{BOT_ID}}"; // never answer its own lines
const POLL_MS = {{POLL_MS}};
const POLL_JITTER_MS = {{POLL_JITTER_MS}};
// Backoff on consecutive failed cycles. Prevents hammering the source
// during an outage or auth break.
const BACKOFF_STEPS = {{BACKOFF_STEPS_MS}};
const MAX_FAILURES = {{MAX_FAILURES}};
const STATE_DIR = `${process.env.HOME}/hooks/state/{{STATE_DIR_NAME}}`;
const QUEUE_FILE = `${STATE_DIR}/{{QUEUE_NAME}}`;
const LAST_SEEN_FILE = `${STATE_DIR}/last-seen.json`;
const ERROR_FILE = `${STATE_DIR}/error.json`;
const WARN_FILE = `${STATE_DIR}/channel-warning.json`; // a channel keeps failing; daemon still running
const PID_FILE = `${STATE_DIR}/daemon.pid`;
const STOP_FILE = `${process.env.HOME}/hooks/state/{{STOP_FILE_NAME}}`;

const CHANNELS: Array<{ id: string; name: string }> = {{CHANNELS}};

type LastSeen = Record<string, string>; // channelId -> newest message id seen

function atomicWriteJson(path: string, obj: unknown) {
  // Write to a temp file in the same directory, fsync, then rename — so a
  // crash or kill mid-write never leaves a truncated state file. The
  // same-directory temp + atomic rename is the load-bearing half.
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2));
  const fd = openSync(tmp, "r+");
  fsyncSync(fd);
  closeSync(fd);
  renameSync(tmp, path);
}

function loadLastSeen(): LastSeen {
  try {
    if (existsSync(LAST_SEEN_FILE)) {
      const parsed = JSON.parse(readFileSync(LAST_SEEN_FILE, "utf8"));
      // Current format: {channels: {...}, polled_at: "..."}. Accept the
      // old plain-map format too, so a filled-in template applied over an
      // existing state file does not re-baseline.
      if (parsed && typeof parsed === "object" && parsed.channels && typeof parsed.channels === "object") {
        return parsed.channels as LastSeen;
      }
      if (parsed && typeof parsed === "object") {
        const { polled_at, ...rest } = parsed;
        return rest as LastSeen;
      }
    }
  } catch {}
  return {};
}
function saveLastSeen(ls: LastSeen) {
  // Heartbeat: written on EVERY successful cycle, not only when items were
  // queued. The worker's liveness check reads `polled_at` — a file whose
  // polled_at is stale past the worker's threshold (poll interval + first
  // backoff step + call timeout) means the daemon is dead, even if the
  // channel cursors are unchanged on a quiet source. Never
  // call this after an all-channels-failed cycle: that would keep
  // polled_at fresh while the daemon is effectively dead.
  mkdirSync(STATE_DIR, { recursive: true });
  atomicWriteJson(LAST_SEEN_FILE, {
    channels: ls,
    polled_at: new Date().toISOString(),
  });
}

function writeError(kind: string, detail: unknown, extra: Record<string, unknown> = {}) {
  // Error marker the worker's liveness check can read. Written when the
  // daemon gives up (auth error, or MAX_FAILURES in a row) before it exits
  // non-zero. Removed on the next successful start.
  mkdirSync(STATE_DIR, { recursive: true });
  atomicWriteJson(ERROR_FILE, {
    kind,
    detail: String(detail).slice(0, 500),
    ...extra,
    at: new Date().toISOString(),
  });
}

function takeDaemonLock() {
  // Only one daemon instance may run: two share the cursors and append
  // every item twice. Bun has no fcntl.flock in its stdlib, so use an
  // exclusive-create pidfile: create it with "wx", and if it already
  // exists, check whether that pid is still alive — a dead pid means a
  // crashed daemon, so remove the stale pidfile and retry once. Remove
  // the pidfile on exit.
  mkdirSync(STATE_DIR, { recursive: true });
  const writePid = () => {
    const fd = openSync(PID_FILE, "wx");
    writeFileSync(fd, String(process.pid));
    closeSync(fd);
  };
  try {
    writePid();
  } catch (e: any) {
    if (e?.code !== "EEXIST") throw e;
    let stale = true;
    try {
      const pid = parseInt(readFileSync(PID_FILE, "utf8").trim(), 10);
      if (Number.isFinite(pid)) {
        try {
          process.kill(pid, 0);
          stale = false; // pid is alive
        } catch {
          stale = true; // pid is dead
        }
      }
    } catch {
      stale = true;
    }
    if (!stale) {
      throw new Error("daemon pidfile held — another instance is running");
    }
    // Stale pidfile from a crashed daemon: remove and retry once.
    try { unlinkSync(PID_FILE); } catch {}
    writePid();
  }
  process.on("exit", () => { try { unlinkSync(PID_FILE); } catch {} });
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
}

// Credential-wide failure: a 401 means the credential itself is expired or
// revoked, whichever channel hit it. Decide on the status the fetch layer
// attaches to the error, never on substrings of the message (ids,
// timestamps and URLs contain "401").
function isCredentialError(e: unknown): boolean {
  return (e as any)?.status === 401;
}

function isAuthError(e: unknown): boolean {
  // Return true when the exception is an auth/permanent failure. Add 403
  // here only where the source documents it as an auth failure; many APIs
  // use 403 for rate limits or for missing access to one channel, which
  // must not take the daemon down (see main for how it is handled).
  return isCredentialError(e);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (s: string) => console.log(`[${new Date().toISOString()}] ${s}`);

async function pollOnce(lastSeen: LastSeen, dryRun: boolean): Promise<{ next: LastSeen; failedChannels: number; failedIds: Set<string>; authError: unknown | null; credentialError: unknown | null }> {
  const next: LastSeen = { ...lastSeen };
  let failedChannels = 0;
  const failedIds = new Set<string>();
  let authError: unknown | null = null;
  let credentialError: unknown | null = null;
  for (const ch of CHANNELS) {
    try {
      const after = lastSeen[ch.id];
      const path = after
        ? `/channels/${ch.id}/messages?limit=25&after=${after}`
        : `/channels/${ch.id}/messages?limit=10`;
      const msgs = (await {{FETCH_CALL}}) as any[];
      // A non-array body (e.g. an error object) is a failure for this
      // channel, not an empty success. An empty array is a quiet success.
      if (!Array.isArray(msgs)) {
        throw Object.assign(new Error("unexpected non-array response"), { status: (msgs as any)?.status });
      }
      if (msgs.length === 0) continue;
      // Source returns newest-first; process oldest-first so the queue stays in order.
      const ordered = [...msgs].reverse();
      const newest = ordered[ordered.length - 1].id;
      if (!after && !dryRun) {
        // First sight of this channel: baseline only, queue nothing (no stale replies).
        next[ch.id] = newest;
        log(`baseline #${ch.name} at ${newest} (${ordered.length} messages seen, queued none)`);
        continue;
      }
      for (const m of ordered) {
        if (m.author?.id === BOT_ID) continue; // never answer our own lines
        {{IS_NEW}}
        const task = {{QUEUE_ITEM}};
        if (dryRun) {
          log(`WOULD QUEUE #${ch.name} ${m.id}`);
        } else {
          mkdirSync(STATE_DIR, { recursive: true });
          appendFileSync(QUEUE_FILE, JSON.stringify(task) + "\n");
          log(`queued #${ch.name} ${m.id}`);
        }
        // Advance the cursor per message, AFTER its append succeeds — so
        // a mid-loop throw does not lose the messages that were already
        // queued (the old code advanced to `newest` before the loop).
        next[ch.id] = m.id;
      }
      // The loop completed: advance past any trailing filtered messages
      // (the bot's own lines, or messages {{IS_NEW}} skipped), so they
      // are not re-fetched on every poll. A mid-loop throw leaves the
      // cursor at the last successfully queued message instead.
      next[ch.id] = newest;
    } catch (e: any) {
      // Per-channel errors are caught here so one bad channel does not
      // stall the others — but they are COUNTED, not swallowed. The caller
      // treats an all-channels-failed cycle as a cycle failure.
      failedChannels++;
      failedIds.add(ch.id);
      if (isAuthError(e)) authError = e;
      if (isCredentialError(e)) credentialError = e;
      log(`#${ch.name} poll failed: ${e.message}`);
    }
  }
  return { next, failedChannels, failedIds, authError, credentialError };
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
  takeDaemonLock();
  // A fresh start clears any error marker from a previous run.
  if (existsSync(ERROR_FILE)) unlinkSync(ERROR_FILE);
  log("{{DAEMON_NAME}} live — {{SOURCE_DESCRIPTION}}, polling every " +
    `${POLL_MS / 1000}s ±${POLL_JITTER_MS / 1000}s jitter (stop file: {{STOP_FILE_NAME}})`);
  let lastSeen = loadLastSeen();
  let consecutiveFailures = 0;
  const channelFailures: Record<string, number> = {};
  while (true) {
    if (existsSync(STOP_FILE)) {
      log("stop file present — exiting");
      return;
    }
    const cycleStart = Date.now();
    try {
      const { next, failedChannels, failedIds, authError, credentialError } = await pollOnce(lastSeen, false);
      // Exit at once only for a credential-wide failure (a 401 on any
      // channel) or when an auth error hit every channel in the cycle. An
      // auth-class error (e.g. a documented 403) on just some channels
      // usually means missing access to those channels, so the others keep
      // being served and the per-channel counter below reports it.
      if (credentialError || (authError && failedChannels === CHANNELS.length)) {
        // A permanent failure (expired/revoked credential) will never
        // succeed by retrying. Mark it and exit non-zero so the worker's
        // liveness check notices instead of the daemon sitting in `ps`
        // looking alive while nothing is ever queued.
        writeError("auth", credentialError ?? authError);
        log("auth error — exiting (check the credential)");
        process.exit(1);
      }
      // Per-channel consecutive failures: a channel that keeps failing
      // while others succeed is flagged (channel-warning.json) but does not stop
      // the daemon.
      for (const ch of CHANNELS) {
        channelFailures[ch.id] = failedIds.has(ch.id) ? (channelFailures[ch.id] ?? 0) + 1 : 0;
        if (channelFailures[ch.id] === MAX_FAILURES && failedChannels < CHANNELS.length) {
          log(`#${ch.name} failed ${MAX_FAILURES} cycles in a row — channel-warning.json written, daemon keeps running`);
        }
      }
      const failing = CHANNELS.filter((ch) => (channelFailures[ch.id] ?? 0) >= MAX_FAILURES).map((ch) => ch.name);
      if (failing.length > 0 && failedChannels < CHANNELS.length) {
        atomicWriteJson(WARN_FILE, { kind: "channel_failing", channels: failing, at: new Date().toISOString() });
      } else if (failing.length === 0 && existsSync(WARN_FILE)) {
        try { unlinkSync(WARN_FILE); } catch {} // the failing channel(s) recovered
      }
      if (failedChannels === CHANNELS.length) {
        // Every channel failed (e.g. a 401 on every read): the daemon is
        // effectively dead, so this counts as a cycle failure. Do NOT
        // saveLastSeen here — that would keep polled_at fresh while the
        // daemon is down.
        consecutiveFailures++;
        log(`all ${CHANNELS.length} channel(s) failed (${consecutiveFailures} in a row)`);
        if (consecutiveFailures >= MAX_FAILURES) {
          writeError("consecutive_failures", "all channels failed");
          log(`${MAX_FAILURES} consecutive failed cycles — exiting`);
          process.exit(1);
        }
      } else {
        lastSeen = next;
        // Heartbeat on every successful cycle, even a quiet one.
        saveLastSeen(lastSeen);
        consecutiveFailures = 0;
      }
    } catch (e: any) {
      consecutiveFailures++;
      log(`cycle error (${consecutiveFailures} in a row): ${e.message}`);
      if (isAuthError(e)) {
        writeError("auth", e);
        log("auth error — exiting (check the credential)");
        process.exit(1);
      }
      if (consecutiveFailures >= MAX_FAILURES) {
        writeError("consecutive_failures", e);
        log(`${MAX_FAILURES} consecutive failures — exiting`);
        process.exit(1);
      }
    }
    const cycleMs = Date.now() - cycleStart;
    if (cycleMs > {{SLOW_CYCLE_MS}}) log(`slow cycle: ${cycleMs}ms (retries likely — watch rate limits)`);
    // Jittered sleep, stretched by backoff after consecutive failures.
    // Backoff applies only after a failure, and the first failure sleeps
    // BACKOFF_STEPS[0] (not the last step).
    let sleepMs: number;
    if (consecutiveFailures > 0) {
      const step = BACKOFF_STEPS[Math.min(consecutiveFailures - 1, BACKOFF_STEPS.length - 1)];
      sleepMs = Math.max(POLL_MS, step);
    } else {
      sleepMs = POLL_MS;
    }
    sleepMs += (Math.random() * 2 - 1) * POLL_JITTER_MS;
    await sleep(Math.max(1000, sleepMs));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
