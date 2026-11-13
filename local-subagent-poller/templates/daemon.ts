#!/usr/bin/env bun
// Tier 1 poller daemon (bun/TypeScript) - a runnable module, not a snippet.
//
// Use this for a REST-polling source with per-channel cursors (a chat-style
// API). For a Python/CLI source use templates/daemon.py. Copy this file,
// poller.config.example.ts.json and an adapter into the new poller's
// directory, edit the config, write (or adapt) the adapter, run:
//
//   bun daemon.ts --config poller.config.json      # or POLLER_CONFIG=...
//   bun daemon.ts --config poller.config.json --dry-run   # one cycle, writes nothing
//
// Everything source-specific lives in the adapter; everything operational
// (timing, backoff, state files, locks, logs) lives here. The baseline,
// per-channel cursor, no-overlap and slow-cycle rules are load-bearing.
//
// Config (JSON; all times in seconds):
//   name                 display name used in the start log
//   state_dir_name       state dir name under <state_root>/
//   stop_file_name       stop file name under <state_root>/
//   poll_secs            poll interval (10 fast API, 60 slow/quiet API)
//   poll_jitter_secs     jitter on the sleep
//   backoff_steps_secs   e.g. [10, 30, 60, 300]; capped, reset on success;
//                        the first failure sleeps backoff_steps_secs[0]
//   slow_call_secs       slow-cycle log threshold
//   call_timeout_secs    timeout for one source call; must be <= poll_secs.
//                        The adapter enforces it (it receives the config).
//   max_failures         consecutive failed cycles before giving up
//                        (error.json, exit non-zero). A 401 exits at once.
//                        One channel failing this many cycles in a row while
//                        others succeed writes channel-warning.json but does
//                        not exit.
//   channels             [{"id": ..., "name": ...}, ...] - at least one
//   adapter              path (./relative to the config file, or absolute) or
//                        module specifier; must export makeSource(config)
//   adapter_options      optional object, free-form, read by the adapter
//   state_root           optional, default ~/hooks/state (env
//                        POLLER_STATE_ROOT overrides the default)
//   queue_lock_wait_secs optional, default 30: how long an append waits for
//                        queue.lock before the cycle counts as failed
//
// Notes:
// - Per-channel errors are caught inside pollOnce so one bad channel does
//   not stall the others - but they are COUNTED, not swallowed. If every
//   channel fails in one cycle (e.g. a 401 on every read) that cycle counts
//   as a failure: the heartbeat is not written, and after max_failures such
//   cycles in a row the daemon writes error.json and exits non-zero. A 401
//   (credential-wide) exits immediately; an auth error on every channel in
//   one cycle does too. A channel failing max_failures cycles in a row while
//   others succeed gets channel-warning.json and the daemon keeps running.
//   This is deliberately NOT error.json: error.json means the daemon gave up
//   and must be restarted.
// - Adapters throw SourceError(message, status). isAuthError reads
//   `status`, never the message text. Rate-limit retry lives in the adapter.
// - First sight of a channel baselines its high-water mark and queues
//   nothing. An empty first poll stays unbaselined for that channel.
// - Logs are JSON lines on stderr and carry channel and item id only -
//   never a username or message text. Queue lines hold the content.
// - Queue appends hold an exclusive flock on <state_dir>/queue.lock and open
//   queue.jsonl by path for each batch. Bun has no flock, so each batch is
//   appended by flock(1) (util-linux), which interoperates with a bash
//   rotator: `flock queue.lock sh -c 'cat >> "$1"' _ queue.jsonl`.
//
// Credentials: read the source token from the environment or a secrets store
// inside the adapter - never hard-code it, never commit it, keep it out of
// logs and queue lines. An expired or revoked credential is a 401
// SourceError; the daemon exits non-zero rather than retrying forever.
//
// Starting the daemon: a supervised service (systemd, launchd) is fine in
// normal environments. Only where network credentials are scoped to an
// agent's tool call (for example an egress-proxy credential that rotates per
// call) must the daemon be started from agent context (a tool call, a cron,
// or a hook), because a service cannot hold a current credential there. A
// long-running daemon keeps working on the credential it started with; in
// such environments, recovery after the host is replaced needs an
// agent-context mechanism.

import { spawnSync } from "node:child_process";
import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync,
  renameSync, unlinkSync, writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export type Item = Record<string, unknown>;
export type Channel = { id: string; name: string };

export class SourceError extends Error {
  status?: number;
  constructor(message: string, status?: number) {
    super(message);
    this.name = "SourceError";
    this.status = status;
  }
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

export class LockError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LockError";
  }
}

export type Config = {
  name: string;
  stateDirName: string;
  stopFileName: string;
  pollSecs: number;
  pollJitterSecs: number;
  backoffStepsSecs: number[];
  slowCallSecs: number;
  callTimeoutSecs: number;
  maxFailures: number;
  channels: Channel[];
  adapter: string;
  adapterOptions: Record<string, unknown>;
  stateRoot: string;
  queueLockWaitSecs: number;
  baseDir: string;
};

/** The source adapter. Items are opaque to the daemon. */
export interface Source {
  /** Recent items, newest first. `since` is the channel cursor, or undefined
   *  when there is none yet (return recent items unfiltered - the daemon
   *  baselines from them and queues none). Throw SourceError on failure. */
  fetch(channel: Channel, since: string | undefined): Promise<Item[]>;
  /** Which items count as queue items. Filter the bot's own items and any
   *  system items. */
  isNew(item: Item, since: string | undefined): boolean;
  /** The cursor value that marks this item as seen. */
  cursorOf(item: Item): string;
  /** The JSONL line per item. Include every field the worker's decision
   *  rules need (who it is for, channel, author, timestamp). */
  toQueueItem(channel: Channel, item: Item): Item;
}

// --------------------------------------------------------------------------
// Config

function num(o: Record<string, unknown>, key: string, min = 0, allowEqual = false): number {
  const v = o[key];
  if (typeof v !== "number" || !Number.isFinite(v)) throw new ConfigError(`config: ${key} must be a number`);
  if (v < min || (v === min && !allowEqual)) {
    throw new ConfigError(`config: ${key} must be ${allowEqual ? ">=" : ">"} ${min}`);
  }
  return v;
}

function plainName(o: Record<string, unknown>, key: string): string {
  const v = o[key];
  if (typeof v !== "string" || !v || v.includes("/") || v === "." || v === "..") {
    throw new ConfigError(`config: ${key} must be a non-empty name without slashes`);
  }
  return v;
}

export function parseConfig(raw: unknown, baseDir = "."): Config {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new ConfigError("config: top level must be a JSON object");
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.name !== "string" || !o.name) throw new ConfigError("config: name must be a non-empty string");
  const pollSecs = num(o, "poll_secs");
  const pollJitterSecs = num(o, "poll_jitter_secs", 0, true);
  const slowCallSecs = num(o, "slow_call_secs");
  const callTimeoutSecs = num(o, "call_timeout_secs");
  if (callTimeoutSecs > pollSecs) {
    throw new ConfigError("config: call_timeout_secs must be <= poll_secs (a call must not overlap the next cycle)");
  }
  const steps = o.backoff_steps_secs;
  if (!Array.isArray(steps) || steps.length === 0 || steps.some((s) => typeof s !== "number" || !(s > 0))) {
    throw new ConfigError("config: backoff_steps_secs must be a non-empty list of positive numbers");
  }
  const maxFailures = o.max_failures;
  if (typeof maxFailures !== "number" || !Number.isInteger(maxFailures) || maxFailures < 1) {
    throw new ConfigError("config: max_failures must be an integer >= 1");
  }
  const chans = o.channels;
  if (!Array.isArray(chans) || chans.length === 0) {
    throw new ConfigError("config: channels must be a non-empty list of {id, name}");
  }
  const channels: Channel[] = chans.map((c: unknown) => {
    const ch = c as Record<string, unknown> | null;
    if (!ch || typeof ch.id !== "string" || !ch.id || typeof ch.name !== "string" || !ch.name) {
      throw new ConfigError("config: each channel needs a non-empty string id and name");
    }
    return { id: ch.id, name: ch.name };
  });
  if (new Set(channels.map((c) => c.id)).size !== channels.length) {
    throw new ConfigError("config: channel ids must be unique");
  }
  if (typeof o.adapter !== "string" || !o.adapter) throw new ConfigError("config: adapter must be a module path string");
  const options = o.adapter_options ?? {};
  if (typeof options !== "object" || options === null || Array.isArray(options)) {
    throw new ConfigError("config: adapter_options must be an object");
  }
  if (o.state_root !== undefined && (typeof o.state_root !== "string" || !o.state_root)) {
    throw new ConfigError("config: state_root must be a non-empty string");
  }
  let root = (o.state_root as string | undefined) ?? process.env.POLLER_STATE_ROOT ?? "~/hooks/state";
  if (root === "~" || root.startsWith("~/")) root = join(homedir(), root.slice(1));
  return {
    name: o.name,
    stateDirName: plainName(o, "state_dir_name"),
    stopFileName: plainName(o, "stop_file_name"),
    pollSecs,
    pollJitterSecs,
    backoffStepsSecs: steps as number[],
    slowCallSecs,
    callTimeoutSecs,
    maxFailures,
    channels,
    adapter: o.adapter,
    adapterOptions: options as Record<string, unknown>,
    stateRoot: root,
    queueLockWaitSecs: "queue_lock_wait_secs" in o ? num(o, "queue_lock_wait_secs") : 30,
    baseDir,
  };
}

export function loadConfig(path: string): Config {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new ConfigError(`config: file not found: ${path}`);
  }
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    throw new ConfigError(`config: invalid JSON in ${path}: ${(e as Error).message}`);
  }
  return parseConfig(raw, dirname(resolve(path)));
}

export async function loadSource(config: Config): Promise<Source> {
  const spec = config.adapter;
  const target = spec.startsWith(".") || isAbsolute(spec)
    ? pathToFileURL(resolve(config.baseDir, spec)).href
    : spec;
  let mod: { makeSource?: unknown };
  try {
    mod = await import(target);
  } catch (e) {
    throw new ConfigError(`config: cannot import adapter ${JSON.stringify(spec)}: ${(e as Error).message}`);
  }
  if (typeof mod.makeSource !== "function") {
    throw new ConfigError(`config: adapter ${JSON.stringify(spec)} does not export makeSource(config)`);
  }
  return await (mod.makeSource as (c: Config) => Source | Promise<Source>)(config);
}

// --------------------------------------------------------------------------
// Paths, logging, state files, locks

const stateDir = (c: Config) => join(c.stateRoot, c.stateDirName);
const stopFile = (c: Config) => join(c.stateRoot, c.stopFileName);

export type LogLevel = "info" | "warn" | "error";
export function log(level: LogLevel, event: string, fields: Record<string, unknown> = {}): void {
  process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }) + "\n");
}

function atomicWriteJson(path: string, obj: unknown): void {
  // Temp file in the same directory, fsync, then rename - so a crash or kill
  // mid-write never leaves a truncated state file.
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2));
  const fd = openSync(tmp, "r+");
  fsyncSync(fd);
  closeSync(fd);
  renameSync(tmp, path);
}

type LastSeen = Record<string, string>; // channelId -> newest item cursor

function loadLastSeen(c: Config): LastSeen {
  try {
    const path = join(stateDir(c), "last-seen.json");
    if (existsSync(path)) {
      const parsed = JSON.parse(readFileSync(path, "utf8"));
      // Current format: {channels: {...}, polled_at}. Accept the old plain
      // map too, so applying this over an existing state file does not
      // re-baseline.
      if (parsed && typeof parsed === "object" && parsed.channels && typeof parsed.channels === "object") {
        return parsed.channels as LastSeen;
      }
      if (parsed && typeof parsed === "object") {
        const { polled_at: _ignored, ...rest } = parsed as Record<string, unknown>;
        return rest as LastSeen;
      }
    }
  } catch {
    // unreadable state: start unbaselined
  }
  return {};
}

function saveLastSeen(c: Config, ls: LastSeen): void {
  // Heartbeat: written on EVERY successful cycle, not only when items were
  // queued. The worker's liveness check reads `polled_at`. Never call this
  // after an all-channels-failed cycle: that would keep polled_at fresh
  // while the daemon is effectively dead.
  mkdirSync(stateDir(c), { recursive: true });
  atomicWriteJson(join(stateDir(c), "last-seen.json"), { channels: ls, polled_at: new Date().toISOString() });
}

function writeError(c: Config, kind: string, detail: unknown): void {
  // Error marker the worker's liveness check reads. Written when the daemon
  // gives up before it exits non-zero. Removed on the next start.
  mkdirSync(stateDir(c), { recursive: true });
  atomicWriteJson(join(stateDir(c), "error.json"), {
    kind,
    detail: String(detail instanceof Error ? detail.message : detail).slice(0, 500),
    at: new Date().toISOString(),
  });
}

/** Single-instance lock: exclusive-create pidfile with a liveness check.
 *  Returns a release function. Throws LockError if another live instance
 *  holds it. */
export function takeDaemonLock(c: Config): () => void {
  const pidFile = join(stateDir(c), "daemon.pid");
  mkdirSync(stateDir(c), { recursive: true });
  const writePid = () => {
    const fd = openSync(pidFile, "wx");
    writeFileSync(fd, String(process.pid));
    closeSync(fd);
  };
  try {
    writePid();
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    let stale = true;
    try {
      const pid = parseInt(readFileSync(pidFile, "utf8").trim(), 10);
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
    if (!stale) throw new LockError("daemon pidfile held - another instance is running");
    // Stale pidfile from a crashed daemon: remove and retry once.
    try { unlinkSync(pidFile); } catch { /* already gone */ }
    writePid();
  }
  return () => { try { unlinkSync(pidFile); } catch { /* already gone */ } };
}

/** Append one batch of JSON lines to queue.jsonl under queue.lock.
 *  Opened by path per batch (via flock(1)) so a rotator's rename is picked
 *  up; synced before the lock is released. */
export function appendQueue(c: Config, lines: string[]): void {
  mkdirSync(stateDir(c), { recursive: true });
  const script = 'cat >> "$1" && { sync -d "$1" 2>/dev/null || sync; }';
  const r = spawnSync(
    "flock",
    ["-w", String(c.queueLockWaitSecs), join(stateDir(c), "queue.lock"), "sh", "-c", script, "_",
      join(stateDir(c), "queue.jsonl")],
    { input: lines.map((l) => l + "\n").join(""), encoding: "utf8" },
  );
  if (r.error) throw new Error(`queue append failed: ${r.error.message}`);
  if (r.status !== 0) {
    throw new Error(`queue append failed (flock exit ${r.status}): ${String(r.stderr).trim().slice(0, 200)}`);
  }
}

// Credential-wide failure: a 401 means the credential itself is expired or
// revoked, whichever channel hit it. Decide on the status, never on
// substrings of the message (ids, timestamps and URLs contain "401").
function isCredentialError(e: unknown): boolean {
  return (e as { status?: unknown } | null)?.status === 401;
}

export function isAuthError(e: unknown): boolean {
  // Add 403 only where the source documents it as an auth failure; many APIs
  // use 403 for rate limits or for missing access to one channel, which must
  // not take the daemon down.
  return isCredentialError(e);
}

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const errStatus = (e: unknown) => (e as { status?: unknown } | null)?.status ?? null;

// --------------------------------------------------------------------------
// Polling

type PollResult = {
  next: LastSeen;
  queued: number;
  failedChannels: number;
  failedIds: Set<string>;
  authError: unknown;
  credentialError: unknown;
};

async function pollOnce(c: Config, source: Source, lastSeen: LastSeen, dryRun: boolean): Promise<PollResult> {
  const next: LastSeen = { ...lastSeen };
  let queued = 0;
  let failedChannels = 0;
  const failedIds = new Set<string>();
  let authError: unknown = null;
  let credentialError: unknown = null;
  for (const ch of c.channels) {
    try {
      const after = lastSeen[ch.id];
      const items = await source.fetch(ch, after);
      // A non-array body is a failure for this channel, not an empty success.
      if (!Array.isArray(items)) {
        throw new SourceError("unexpected non-array response");
      }
      if (items.length === 0) {
        if (after === undefined) log("info", "baseline_empty", { channel: ch.name });
        continue;
      }
      const newest = source.cursorOf(items[0]);
      if (after === undefined) {
        // First sight of this channel: baseline only, queue nothing.
        if (!dryRun) next[ch.id] = newest;
        log("info", "baseline", { channel: ch.name, cursor: newest, seen: items.length, queued: 0 });
        continue;
      }
      // Source returns newest-first; queue oldest-first.
      const fresh = items.filter((i) => source.isNew(i, after)).reverse();
      if (fresh.length > 0) {
        if (dryRun) {
          log("info", "would_queue", { channel: ch.name, count: fresh.length });
        } else {
          appendQueue(c, fresh.map((i) => JSON.stringify(source.toQueueItem(ch, i))));
          queued += fresh.length;
          log("info", "queued", { channel: ch.name, count: fresh.length, cursor: newest });
        }
      }
      // Advance only after the batch append succeeded (a throw above leaves
      // the cursor where it was); also moves past trailing filtered items.
      if (!dryRun) next[ch.id] = newest;
    } catch (e) {
      // Counted, not swallowed: the caller treats an all-channels-failed
      // cycle as a cycle failure.
      failedChannels++;
      failedIds.add(ch.id);
      if (isAuthError(e)) authError = e;
      if (isCredentialError(e)) credentialError = e;
      log("warn", "channel_failed", { channel: ch.name, error: errMsg(e).slice(0, 500), status: errStatus(e) });
    }
  }
  return { next, queued, failedChannels, failedIds, authError, credentialError };
}

export type RunOptions = {
  maxPolls?: number;
  dryRun?: boolean;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  random?: () => number;
};

/** The daemon loop. Resolves with the process exit code (0 = clean stop or
 *  max polls reached, 1 = gave up or auth error). Throws LockError if
 *  another instance holds the pidfile. */
export async function run(c: Config, source: Source, opts: RunOptions = {}): Promise<number> {
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const now = opts.now ?? Date.now;
  const random = opts.random ?? Math.random;
  mkdirSync(stateDir(c), { recursive: true });
  if (opts.dryRun) {
    log("info", "dry_run", { detail: "one cycle, writing nothing" });
    await pollOnce(c, source, loadLastSeen(c), true);
    log("info", "dry_run_done");
    return 0;
  }
  const release = takeDaemonLock(c);
  try {
    const errorFile = join(stateDir(c), "error.json");
    const warnFile = join(stateDir(c), "channel-warning.json"); // a channel keeps failing; daemon still running
    if (existsSync(errorFile)) unlinkSync(errorFile); // a fresh start clears the old marker
    log("info", "start", { name: c.name, poll_secs: c.pollSecs, jitter_secs: c.pollJitterSecs,
      stop_file: c.stopFileName, channels: c.channels.map((ch) => ch.name) });
    let lastSeen = loadLastSeen(c);
    let failures = 0;
    let polls = 0;
    const channelFailures: Record<string, number> = {};
    while (true) {
      if (existsSync(stopFile(c))) {
        log("info", "stop", { detail: "stop file present" });
        return 0;
      }
      const start = now();
      let backoffSecs: number | null = null;
      const stepFor = (n: number) => c.backoffStepsSecs[Math.min(n - 1, c.backoffStepsSecs.length - 1)];
      try {
        const res = await pollOnce(c, source, lastSeen, false);
        // Exit at once only for a credential-wide failure (a 401 on any
        // channel) or when an auth error hit every channel in the cycle.
        if (res.credentialError || (res.authError && res.failedChannels === c.channels.length)) {
          writeError(c, "auth", res.credentialError ?? res.authError);
          log("error", "auth_error", { detail: "exiting - check the credential" });
          return 1;
        }
        // Per-channel consecutive failures: a channel that keeps failing
        // while others succeed is flagged but does not stop the daemon.
        for (const ch of c.channels) {
          channelFailures[ch.id] = res.failedIds.has(ch.id) ? (channelFailures[ch.id] ?? 0) + 1 : 0;
          if (channelFailures[ch.id] === c.maxFailures && res.failedChannels < c.channels.length) {
            log("warn", "channel_warning", { channel: ch.name, failures: c.maxFailures,
              detail: "channel-warning.json written, daemon keeps running" });
          }
        }
        const failing = c.channels.filter((ch) => (channelFailures[ch.id] ?? 0) >= c.maxFailures).map((ch) => ch.name);
        if (failing.length > 0 && res.failedChannels < c.channels.length) {
          atomicWriteJson(warnFile, { kind: "channel_failing", channels: failing, at: new Date().toISOString() });
        } else if (failing.length === 0 && existsSync(warnFile)) {
          try { unlinkSync(warnFile); } catch { /* already gone */ }
          log("info", "channel_recovered", { detail: "channel-warning.json removed" });
        }
        if (res.failedChannels === c.channels.length) {
          // Every channel failed: the daemon is effectively dead, so this
          // counts as a cycle failure. No heartbeat.
          failures++;
          backoffSecs = stepFor(failures);
          log("warn", "poll_failed", { attempt: failures, max_failures: c.maxFailures, backoff_secs: backoffSecs,
            error: `all ${c.channels.length} channel(s) failed` });
          if (failures >= c.maxFailures) {
            writeError(c, "consecutive_failures", "all channels failed");
            log("error", "give_up", { failures });
            return 1;
          }
        } else {
          lastSeen = res.next;
          // Heartbeat on every successful cycle, even a quiet one.
          saveLastSeen(c, lastSeen);
          failures = 0;
          log("info", "poll_ok", { queued: res.queued, failed_channels: res.failedChannels,
            duration_ms: now() - start });
        }
      } catch (e) {
        failures++;
        backoffSecs = stepFor(failures);
        log("warn", "poll_failed", { attempt: failures, max_failures: c.maxFailures, backoff_secs: backoffSecs,
          error: errMsg(e).slice(0, 500), status: errStatus(e) });
        if (isAuthError(e)) {
          writeError(c, "auth", e);
          log("error", "auth_error", { detail: "exiting - check the credential" });
          return 1;
        }
        if (failures >= c.maxFailures) {
          writeError(c, "consecutive_failures", e);
          log("error", "give_up", { failures });
          return 1;
        }
      }
      const cycleMs = now() - start;
      if (cycleMs > c.slowCallSecs * 1000) {
        log("warn", "poll_slow", { duration_ms: cycleMs, threshold_secs: c.slowCallSecs });
      }
      polls++;
      if (opts.maxPolls !== undefined && polls >= opts.maxPolls) return 0;
      // Jittered sleep, stretched by backoff after failures. The first
      // failure sleeps backoff_steps[0] (not the last step).
      let sleepMs = (backoffSecs === null ? c.pollSecs : Math.max(c.pollSecs, backoffSecs)) * 1000;
      sleepMs += (random() * 2 - 1) * c.pollJitterSecs * 1000;
      await sleep(Math.max(1000, sleepMs));
    }
  } finally {
    release();
  }
}

export async function main(argv: string[] = process.argv.slice(2)): Promise<number> {
  let path = process.env.POLLER_CONFIG;
  const i = argv.indexOf("--config");
  if (i >= 0) path = argv[i + 1];
  let config: Config;
  let source: Source;
  try {
    if (!path) throw new ConfigError("config: pass --config PATH or set POLLER_CONFIG");
    config = loadConfig(path);
    source = await loadSource(config);
  } catch (e) {
    log("error", "config_error", { detail: errMsg(e) });
    return 2;
  }
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
  try {
    return await run(config, source, { dryRun: argv.includes("--dry-run") });
  } catch (e) {
    log("error", e instanceof LockError ? "already_running" : "fatal", { detail: errMsg(e) });
    return 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(await main());
}
