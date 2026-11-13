import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as daemon from "../../local-subagent-poller/templates/daemon.ts";
import { FakeSource } from "./fake-adapter.ts";

const TEMPLATES = join(import.meta.dir, "../../local-subagent-poller/templates");
let root: string;
const realWrite = process.stderr.write.bind(process.stderr);
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "poller-ts-"));
  (process.stderr as any).write = () => true; // keep test output quiet; withLogs captures when needed
});
afterEach(() => {
  process.stderr.write = realWrite;
  rmSync(root, { recursive: true, force: true });
});

function cfg(over: Record<string, unknown> = {}): daemon.Config {
  return daemon.parseConfig({
    name: "test watcher", state_dir_name: "s", stop_file_name: "stop",
    poll_secs: 60, poll_jitter_secs: 0, backoff_steps_secs: [60, 120, 300],
    slow_call_secs: 10, call_timeout_secs: 30, max_failures: 3,
    channels: [{ id: "c1", name: "team-queue" }, { id: "c2", name: "other" }],
    adapter: "./fake-adapter.ts", adapter_options: { self_id: "bot" },
    state_root: root, queue_lock_wait_secs: 5, ...over,
  }, import.meta.dir);
}
const sd = (c: daemon.Config) => join(c.stateRoot, c.stateDirName);
const readJson = (p: string) => JSON.parse(readFileSync(p, "utf8"));
const queue = (c: daemon.Config) => {
  const p = join(sd(c), "queue.jsonl");
  return existsSync(p) ? readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const noSleep = async () => {};

// Capture JSON log lines written to stderr during fn.
async function withLogs<T>(fn: () => Promise<T>): Promise<{ result: T; logs: Record<string, any>[] }> {
  const orig = process.stderr.write.bind(process.stderr);
  const chunks: string[] = [];
  (process.stderr as any).write = (s: string | Uint8Array) => { chunks.push(String(s)); return true; };
  try {
    const result = await fn();
    return { result, logs: chunks.join("").split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
  } finally {
    process.stderr.write = orig;
  }
}

test("baseline, then new items queued oldest first with the right shape", async () => {
  const c = cfg();
  const src = new FakeSource();
  src.push("c1", "old");
  await run1(c, src);
  expect(queue(c)).toEqual([]);
  src.push("c1", "hello");
  src.push("c1", "from bot", "bot");
  src.push("c1", "second");
  await run1(c, src);
  expect(queue(c)).toEqual([
    { id: "2", channel_id: "c1", channel_name: "team-queue", author_id: "alice", text: "hello" },
    { id: "4", channel_id: "c1", channel_name: "team-queue", author_id: "alice", text: "second" },
  ]);
  expect(readJson(join(sd(c), "last-seen.json")).channels.c1).toBe("4");
});
const run1 = (c: daemon.Config, s: FakeSource) => daemon.run(c, s, { maxPolls: 1, sleep: noSleep });

test("empty poll writes the heartbeat and stays unbaselined", async () => {
  const c = cfg();
  const src = new FakeSource();
  expect(await run1(c, src)).toBe(0);
  const ls = readJson(join(sd(c), "last-seen.json"));
  expect(ls.channels).toEqual({});
  expect(typeof ls.polled_at).toBe("string");
  src.push("c1", "x");
  await run1(c, src);
  expect(queue(c)).toEqual([]);
  await run1(c, src); // quiet poll: cursor unchanged, heartbeat refreshed
  const ls2 = readJson(join(sd(c), "last-seen.json"));
  expect(ls2.channels).toEqual({ c1: "1" });
  expect(ls2.polled_at >= ls.polled_at).toBe(true);
});

test("all channels failing: backoff, then error.json and exit 1; no heartbeat", async () => {
  const c = cfg();
  const src = new FakeSource();
  src.fail("c1", 500);
  src.fail("c2", 502);
  const sleeps: number[] = [];
  const { result: code, logs } = await withLogs(() =>
    daemon.run(c, src, { sleep: async (ms) => { sleeps.push(ms); } }));
  expect(code).toBe(1);
  expect(sleeps).toEqual([60000, 120000]);
  expect(readJson(join(sd(c), "error.json")).kind).toBe("consecutive_failures");
  expect(existsSync(join(sd(c), "last-seen.json"))).toBe(false);
  const failed = logs.filter((l) => l.event === "poll_failed");
  expect(failed.map((l) => l.attempt)).toEqual([1, 2, 3]);
  expect(failed[0].backoff_secs).toBe(60);
  expect(logs.at(-1)!.event).toBe("give_up");
});

test("backoff caps and resets after recovery", async () => {
  const c = cfg({ max_failures: 10, backoff_steps_secs: [10, 20], poll_secs: 5, call_timeout_secs: 5 });
  const src = new FakeSource();
  src.fail("c1", 503);
  src.fail("c2", 503);
  const sleeps: number[] = [];
  await daemon.run(c, src, { maxPolls: 6, sleep: async (ms) => {
    sleeps.push(ms);
    if (sleeps.length === 4) { src.recover("c1"); src.recover("c2"); }
  } });
  expect(sleeps).toEqual([10000, 20000, 20000, 20000, 5000]);
});

test("a 401 is an auth error and exits immediately; message text is ignored", async () => {
  const c = cfg({ max_failures: 5 });
  const src = new FakeSource();
  src.fail("c1", 401, "expired");
  const { result, logs } = await withLogs(() => daemon.run(c, src, { sleep: noSleep }));
  expect(result).toBe(1);
  expect(readJson(join(sd(c), "error.json")).kind).toBe("auth");
  expect(logs.some((l) => l.event === "auth_error")).toBe(true);

  const c2 = cfg({ state_dir_name: "s2", max_failures: 2 });
  const src2 = new FakeSource();
  src2.fail("c1", 500, "id 401 failed");
  src2.fail("c2", 500, "id 401 failed");
  await withLogs(() => daemon.run(c2, src2, { sleep: noSleep }));
  expect(readJson(join(sd(c2), "error.json")).kind).toBe("consecutive_failures");
});

test("a second instance is refused; a stale pidfile is replaced", async () => {
  const c = cfg();
  const release = daemon.takeDaemonLock(c);
  try {
    await expect(daemon.run(c, new FakeSource(), { maxPolls: 1, sleep: noSleep })).rejects.toBeInstanceOf(daemon.LockError);
  } finally {
    release();
  }
  expect(existsSync(join(sd(c), "daemon.pid"))).toBe(false);
  writeFileSync(join(sd(c), "daemon.pid"), "2147483646"); // dead pid
  expect(await run1(c, new FakeSource())).toBe(0);
  expect(existsSync(join(sd(c), "daemon.pid"))).toBe(false);
});

test("stop file ends the loop cleanly", async () => {
  const c = cfg();
  const { result, logs } = await withLogs(() =>
    daemon.run(c, new FakeSource(), { sleep: async () => { writeFileSync(join(root, "stop"), ""); } }));
  expect(result).toBe(0);
  expect(logs.at(-1)!.event).toBe("stop");
});

test("channel-warning.json written at the threshold and removed on recovery", async () => {
  const c = cfg({ max_failures: 3 });
  const src = new FakeSource();
  src.push("c1", "a");
  src.push("c2", "b");
  src.fail("c2", 500);
  const warn = join(sd(c), "channel-warning.json");
  const seen: boolean[] = [];
  const { result, logs } = await withLogs(() => daemon.run(c, src, { maxPolls: 5, sleep: async () => {
    seen.push(existsSync(warn));
    if (seen.length === 4) src.recover("c2");
  } }));
  expect(result).toBe(0);
  // after polls 1,2: absent; poll 3 hits the threshold; stays through 4; recovered after 5
  expect(seen).toEqual([false, false, true, true]);
  expect(existsSync(warn)).toBe(false);
  expect(logs.some((l) => l.event === "channel_warning" && l.channel === "other")).toBe(true);
  expect(logs.some((l) => l.event === "channel_recovered")).toBe(true);
  expect(existsSync(join(sd(c), "error.json"))).toBe(false);
  expect(existsSync(join(sd(c), "last-seen.json"))).toBe(true); // heartbeat kept while c1 healthy
});

test("channel-warning content names the failing channel", async () => {
  const c = cfg({ max_failures: 2 });
  const src = new FakeSource();
  src.push("c1", "a");
  src.fail("c2", 500);
  await withLogs(() => daemon.run(c, src, { maxPolls: 2, sleep: noSleep }));
  const w = readJson(join(sd(c), "channel-warning.json"));
  expect(w.kind).toBe("channel_failing");
  expect(w.channels).toEqual(["other"]);
});

test("appends wait for queue.lock and go through it", async () => {
  const c = cfg();
  mkdirSync(sd(c), { recursive: true });
  const holder = spawn("flock", [join(sd(c), "queue.lock"), "sleep", "1"]);
  await Bun.sleep(200); // let flock take the lock
  const t0 = Date.now();
  const child = spawn("bun", ["-e", `
    import { parseConfig, appendQueue } from ${JSON.stringify(join(TEMPLATES, "daemon.ts"))};
    const c = parseConfig(${JSON.stringify({
      name: "t", state_dir_name: "s", stop_file_name: "stop", poll_secs: 60, poll_jitter_secs: 0,
      backoff_steps_secs: [60], slow_call_secs: 10, call_timeout_secs: 30, max_failures: 3,
      channels: [{ id: "c1", name: "n" }], adapter: "x", state_root: root, queue_lock_wait_secs: 10,
    })});
    appendQueue(c, ['{"a":1}']);
  `]);
  const exited = new Promise<number | null>((r) => child.on("exit", r));
  await Bun.sleep(300);
  expect(queue(c)).toEqual([]); // still blocked by the held lock
  expect(await exited).toBe(0);
  expect(Date.now() - t0).toBeGreaterThan(600);
  expect(queue(c)).toEqual([{ a: 1 }]);
  holder.kill();
});

test("append reopens the queue by path after a rename", () => {
  const c = cfg();
  daemon.appendQueue(c, ['{"n":1}']);
  const q = join(sd(c), "queue.jsonl");
  renameSync(q, q + ".archive"); // what the rotator does under the lock
  daemon.appendQueue(c, ['{"n":2}']);
  expect(queue(c)).toEqual([{ n: 2 }]);
  expect(existsSync(join(sd(c), "queue.lock"))).toBe(true);
});

test("append lock timeout counts as a failure and does not advance the cursor", async () => {
  const c = cfg({ queue_lock_wait_secs: 1, max_failures: 1, channels: [{ id: "c1", name: "team-queue" }] });
  const src = new FakeSource();
  src.push("c1", "a");
  await run1(c, src);
  src.push("c1", "b");
  const holder = spawn("flock", [join(sd(c), "queue.lock"), "sleep", "3"]);
  await Bun.sleep(200);
  const { result } = await withLogs(() => daemon.run(c, src, { sleep: noSleep }));
  holder.kill();
  expect(result).toBe(1); // the only channel failed every cycle
  expect(readJson(join(sd(c), "last-seen.json")).channels).toEqual({ c1: "1" });
});

test("slow cycle is logged", async () => {
  const c = cfg();
  let t = 0;
  const ticks = [0, 12000, 12000];
  const { logs } = await withLogs(() => daemon.run(c, new FakeSource(), {
    maxPolls: 1, sleep: noSleep, now: () => ticks[Math.min(t++, ticks.length - 1)] }));
  expect(logs.some((l) => l.event === "poll_slow" && l.level === "warn")).toBe(true);
});

test("logs are JSON lines and never carry message text", async () => {
  const c = cfg();
  const src = new FakeSource();
  src.push("c1", "secret text");
  const { logs } = await withLogs(async () => { await daemon.run(c, src, { maxPolls: 2, sleep: noSleep }); });
  for (const l of logs) {
    expect(["info", "warn", "error"]).toContain(l.level);
    expect(typeof l.event).toBe("string");
    expect(Number.isNaN(Date.parse(l.ts))).toBe(false);
    expect(l.ts.endsWith("Z")).toBe(true);
  }
  expect(new Set(logs.map((l) => l.event))).toContainEqual("start");
  expect(JSON.stringify(logs)).not.toContain("secret text");
});

test("old plain-map last-seen format is honoured", async () => {
  const c = cfg();
  mkdirSync(sd(c), { recursive: true });
  writeFileSync(join(sd(c), "last-seen.json"), JSON.stringify({ c1: "1", c2: "0" }));
  const src = new FakeSource();
  src.push("c1", "a");
  src.push("c1", "b");
  await run1(c, src);
  expect(queue(c).map((q) => q.text)).toEqual(["b"]);
});

test("dry run writes nothing", async () => {
  const c = cfg();
  const src = new FakeSource();
  src.push("c1", "a");
  await run1(c, src);
  src.push("c1", "b");
  const before = readFileSync(join(sd(c), "last-seen.json"), "utf8");
  await daemon.run(c, src, { dryRun: true });
  expect(queue(c)).toEqual([]);
  expect(readFileSync(join(sd(c), "last-seen.json"), "utf8")).toBe(before);
});

test("config validation fails fast", () => {
  const bad: Array<Record<string, unknown>> = [
    { poll_secs: 0 }, { call_timeout_secs: 90 }, { backoff_steps_secs: [] }, { max_failures: 0 },
    { channels: [] }, { adapter: "" }, { state_dir_name: "a/b" },
    { channels: [{ id: "x", name: "a" }, { id: "x", name: "b" }] },
  ];
  for (const over of bad) expect(() => cfg(over)).toThrow(daemon.ConfigError);
});

test("adapter loading: relative path, missing export, missing module", async () => {
  expect(await daemon.loadSource(cfg())).toBeDefined();
  writeFileSync(join(root, "bad.ts"), "export const x = 1;\n");
  await expect(daemon.loadSource(cfg({ adapter: join(root, "bad.ts") }))).rejects.toBeInstanceOf(daemon.ConfigError);
  await expect(daemon.loadSource(cfg({ adapter: "./nope.ts" }))).rejects.toBeInstanceOf(daemon.ConfigError);
});

test("example config parses and example adapter loads", async () => {
  const c = daemon.loadConfig(join(TEMPLATES, "poller.config.example.ts.json"));
  const src = await daemon.loadSource(c);
  expect(typeof src.fetch).toBe("function");
});

test("CLI: missing config exits 2 with a JSON error", () => {
  const r = spawnSync("bun", [join(TEMPLATES, "daemon.ts"), "--config", join(root, "nope.json")], { encoding: "utf8" });
  expect(r.status).toBe(2);
  expect(JSON.parse(r.stderr.trim().split("\n").at(-1)!).event).toBe("config_error");
});
