#!/usr/bin/env python3
"""{{DAEMON_NAME}} (tier 1 daemon) — TEMPLATE.
Extracted from the production fleet-queue watcher (Nov 13 2026).
Copy this file into the new poller's directory and fill in the {{...}}
placeholders. Keep the structure verbatim — the baseline, backoff,
no-overlap, and slow-call rules are load-bearing.

Fill in ({{POLL_SECS}} is a bare integer, e.g. 60 — not "60s"):
  {{DAEMON_NAME}}     — e.g. "fleet-queue watcher"
  {{STATE_DIR_NAME}}  — state dir name under ~/hooks/state/, e.g. "fleet-queue"
  {{STOP_FILE_NAME}}  — stop file name under ~/hooks/state/, e.g. "fleet-queue-stop"
  {{POLL_SECS}}       — poll interval, set from the source (10 fast API,
                        60 slow/quiet API). The worker's poll must match this.
  {{POLL_JITTER_SECS}}— jitter on the sleep, e.g. 5
  {{BACKOFF_STEPS}}   — e.g. [60, 120, 300] for a 60s poll, [10, 30, 60, 300]
                        for a 10s poll. Cap, reset on success. The first
                        failure sleeps BACKOFF_STEPS[0].
  {{SLOW_CALL_SECS}}  — slow-call threshold, e.g. 10
  {{CALL_TIMEOUT}}    — timeout for one source call, e.g. 60. Must be
                        <= POLL_SECS so a call can never overlap the next cycle.
  read_source(oldest) — replace the stub below with the real source read.
                        It must return a list of message dicts, newest first,
                        each with at least the fields queue_item() needs.
                        `oldest` is the last-seen cursor; the sentinel "0"
                        means "no cursor yet" — return the recent messages
                        unfiltered (the caller baselines from them, it does
                        not queue them). Raise on failure — the caller
                        handles backoff. Rate-limit retry (prompt,
                        `retry_after` seconds) lives here, in the fetch
                        layer; failure backoff (minutes) lives in the caller.
                        For a CLI-based read, import subprocess/tempfile here.
  is_new(m)           — replace the stub below: which messages count as
                        queue items. Filter the bot's own messages and any
                        subtype/system messages the source emits.
  queue_item(m)       — replace the shape below: the JSONL line per item.
                        Include every field the worker's decision rules need
                        (who it is for, thread state, reply count) — a
                        minimal {ts, text} loses them and forces the worker
                        to re-fetch per item.
"""
import json
import os
import random
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, "hooks/state/{{STATE_DIR_NAME}}")
QUEUE_FILE = os.path.join(STATE_DIR, "queue.jsonl")
LAST_SEEN_FILE = os.path.join(STATE_DIR, "last-seen.json")
STOP_FILE = os.path.join(HOME, "hooks/state/{{STOP_FILE_NAME}}")
POLL_SECS = {{POLL_SECS}}
POLL_JITTER_SECS = {{POLL_JITTER_SECS}}
BACKOFF_STEPS = {{BACKOFF_STEPS}}
SLOW_CALL_SECS = {{SLOW_CALL_SECS}}
CALL_TIMEOUT = {{CALL_TIMEOUT}}


def log(msg):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)


def load_last_seen():
    try:
        with open(LAST_SEEN_FILE) as f:
            return json.load(f).get("ts", "0")
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        return "0"


def save_last_seen(ts):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(LAST_SEEN_FILE, "w") as f:
        json.dump({"ts": ts}, f)


def read_source(oldest):
    # TODO: replace with the real source read. Must return a list of
    # message dicts, newest first. Pass `oldest` (the last-seen cursor)
    # so most polls return zero messages. Keep the call's timeout at or
    # below CALL_TIMEOUT. Raise on failure — the caller handles backoff.
    raise NotImplementedError("fill in read_source for this poller")


def is_new(m, last_seen):
    # TODO: replace with the source's filter. Production examples:
    #   Slack: skip subtype messages and the bot's own messages.
    #   Discord: skip the bot's own messages; require a mention of the bot.
    # A default of `ts > last_seen` alone is unsafe — it queues the bot's
    # own replies as new work.
    raise NotImplementedError("fill in is_new for this poller")


def queue_item(m):
    # TODO: replace with the queue line shape for this poller. Default to
    # the full shape the worker's decision rules need; trim only fields
    # the worker provably never reads. Production examples:
    #   Slack: {ts, thread_ts, user, text, reply_count}
    #   Discord: {message_id, channel_id, channel_name, author_id,
    #             author_username, content, timestamp}
    return {
        "ts": m.get("ts"),
        "thread_ts": m.get("thread_ts"),
        "user": m.get("user"),
        "text": m.get("text", ""),
        "reply_count": m.get("reply_count", 0),
    }


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    log("{{DAEMON_NAME}} live — polling every "
        f"{POLL_SECS}s ±{POLL_JITTER_SECS}s jitter (stop file: {{STOP_FILE_NAME}})")
    last_seen = load_last_seen()
    baselined = last_seen != "0"
    consecutive_failures = 0
    while True:
        if os.path.exists(STOP_FILE):
            log("stop file present — exiting")
            return
        start = time.time()
        try:
            messages = read_source(last_seen if baselined else None)
            # Newest-first from the source; keep only new items, oldest first.
            new = [m for m in messages if is_new(m, last_seen)]
            new.reverse()
            if not baselined:
                # Only baseline when the first poll actually saw messages.
                # An empty first poll must NOT mark us baselined: with
                # last_seen stuck at "0", the next poll would treat the
                # whole recent history as new work.
                if messages:
                    last_seen = messages[0].get("ts", last_seen)
                    save_last_seen(last_seen)
                    baselined = True
                    log(f"baseline at ts {last_seen} "
                        f"({len(messages)} messages seen, queued none)")
                else:
                    log("first poll saw no messages — staying unbaselined")
            else:
                for m in new:
                    with open(QUEUE_FILE, "a") as f:
                        f.write(json.dumps(queue_item(m)) + "\n")
                    last_seen = m.get("ts", last_seen)
                if new:
                    save_last_seen(last_seen)
                    log(f"queued {len(new)} new item(s), latest ts {last_seen}")
            consecutive_failures = 0
        except Exception as e:
            consecutive_failures += 1
            log(f"poll error ({consecutive_failures} in a row): {e}")
        elapsed = time.time() - start
        if elapsed > SLOW_CALL_SECS:
            log(f"slow poll: {elapsed:.1f}s (source slow — watch rate limits)")
        step = BACKOFF_STEPS[min(max(consecutive_failures - 1, 0),
                                 len(BACKOFF_STEPS) - 1)]
        sleep_s = max(POLL_SECS, step) + random.uniform(-1, 1) * POLL_JITTER_SECS
        time.sleep(max(5, sleep_s))


if __name__ == "__main__":
    main()
