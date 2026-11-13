#!/usr/bin/env python3
"""{{DAEMON_NAME}} (tier 1 daemon) — TEMPLATE.
Extracted from a production team-queue watcher (Nov 13 2026).
Copy this file into the new poller's directory and fill in the {{...}}
placeholders. Keep the structure verbatim — the baseline, backoff,
no-overlap, and slow-call rules are load-bearing.

Fill in ({{POLL_SECS}} is a bare integer, e.g. 60 — not "60s"):
  {{DAEMON_NAME}}     — e.g. "team-queue watcher"
  {{STATE_DIR_NAME}}  — state dir name under ~/hooks/state/, e.g. "team-queue"
  {{STOP_FILE_NAME}}  — stop file name under ~/hooks/state/, e.g. "team-queue-stop"
  {{POLL_SECS}}       — poll interval, set from the source (10 fast API,
                        60 slow/quiet API). The worker's poll must match this.
  {{POLL_JITTER_SECS}}— jitter on the sleep, e.g. 5
  {{BACKOFF_STEPS}}   — e.g. [60, 120, 300] for a 60s poll, [10, 30, 60, 300]
                        for a 10s poll. Cap, reset on success. The first
                        failure sleeps BACKOFF_STEPS[0].
  {{SLOW_CALL_SECS}}  — slow-call threshold, e.g. 10
  {{CALL_TIMEOUT}}    — timeout for one source call, e.g. 60. Must be
                        <= POLL_SECS so a call can never overlap the next cycle.
  {{MAX_FAILURES}}    — consecutive failures before the daemon gives up
                        and exits non-zero, e.g. 5. An auth error exits
                        immediately, without waiting for this count.
  read_source(oldest) — replace the stub below with the real source read.
                        It must return a list of message dicts, newest first,
                        each with at least the fields queue_item() needs.
                        `oldest` is the last-seen cursor, or None when there
                        is no cursor yet — return the recent messages
                        unfiltered (the caller baselines from them, it does
                        not queue them). The "0" sentinel is the last_seen
                        value meaning "no cursor", used by load_last_seen;
                        read_source itself receives None, not "0". Raise on
                        failure — the caller handles backoff. Rate-limit
                        retry (prompt, `retry_after` seconds) lives here, in
                        the fetch layer; failure backoff (minutes) lives in
                        the caller. For a CLI-based read, import
                        subprocess/tempfile here.
  is_new(m, last_seen) — replace the stub below: which messages count as
                        queue items. Filter the bot's own messages and any
                        subtype/system messages the source emits.
  queue_item(m)       — replace the shape below: the JSONL line per item.
                        Include every field the worker's decision rules need
                        (who it is for, thread state, reply count) — a
                        minimal {ts, text} loses them and forces the worker
                        to re-fetch per item.
  is_auth_error(e)    — the default treats a SourceError with status 401
                        as an auth failure, so the daemon exits instead of
                        retrying forever. Extend it only where the source
                        documents other statuses (e.g. 403) as auth failures.

Credentials: read the source token from the environment or a secrets
store — never hard-code it in the filled-in template and never commit it.
Keep it out of logs and queue lines, and handle expiry explicitly: an
expired or revoked credential raises an auth error (see is_auth_error),
and the daemon exits non-zero rather than retrying forever.

Starting the daemon: a supervised service (systemd, launchd) is fine in
normal environments. Only where network credentials are scoped to an
agent's tool call (for example an egress-proxy credential that rotates per
call) must the daemon be started from agent context (a tool call, a cron,
or a hook), because a service cannot hold a current credential there. A
long-running daemon keeps working on the credential it started with; in
such environments, recovery after the host is replaced needs an
agent-context mechanism.
"""
import fcntl
import json
import os
import random
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, "hooks/state/{{STATE_DIR_NAME}}")
QUEUE_FILE = os.path.join(STATE_DIR, "queue.jsonl")
LAST_SEEN_FILE = os.path.join(STATE_DIR, "last-seen.json")
ERROR_FILE = os.path.join(STATE_DIR, "error.json")
DAEMON_LOCK_FILE = os.path.join(STATE_DIR, "daemon.lock")
STOP_FILE = os.path.join(HOME, "hooks/state/{{STOP_FILE_NAME}}")
POLL_SECS = {{POLL_SECS}}
POLL_JITTER_SECS = {{POLL_JITTER_SECS}}
BACKOFF_STEPS = {{BACKOFF_STEPS}}
SLOW_CALL_SECS = {{SLOW_CALL_SECS}}
CALL_TIMEOUT = {{CALL_TIMEOUT}}
MAX_FAILURES = {{MAX_FAILURES}}


class SourceError(Exception):
    """Raised by read_source on a failed call. `status` is the HTTP status
    (or None when there is none) so is_auth_error can decide on the status,
    not on substrings of the message."""

    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def log(msg):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)


def atomic_write_json(path, obj):
    # Write to a temp file in the same directory, fsync, then replace —
    # so a crash or kill mid-write never leaves a truncated state file.
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(obj, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load_last_seen():
    try:
        with open(LAST_SEEN_FILE) as f:
            return json.load(f).get("ts", "0")
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        return "0"


def save_last_seen(ts):
    # Heartbeat: written on EVERY successful poll, not only when items
    # were queued. The worker's liveness check reads `polled_at` — a file
    # whose polled_at is stale past the worker's threshold (poll interval
    # + first backoff step + call timeout) means the daemon is dead, even
    # if `ts` is unchanged on a quiet source.
    os.makedirs(STATE_DIR, exist_ok=True)
    atomic_write_json(LAST_SEEN_FILE, {
        "ts": ts,
        "polled_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })


def write_error(kind, detail):
    # Error marker the worker's liveness check can read. Written when the
    # daemon gives up (auth error, or MAX_FAILURES in a row) before it
    # exits non-zero. Removed on the next successful start.
    os.makedirs(STATE_DIR, exist_ok=True)
    atomic_write_json(ERROR_FILE, {
        "kind": kind,
        "detail": str(detail)[:500],
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })


def take_daemon_lock():
    # Only one daemon instance may run: two share the cursor and append
    # every item twice. Take an exclusive flock on a lockfile in STATE_DIR
    # at startup and hold it for the daemon's lifetime (flock is released
    # automatically if the process dies). Exit non-zero if it is held.
    os.makedirs(STATE_DIR, exist_ok=True)
    fd = os.open(DAEMON_LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise SystemExit("daemon lock held — another instance is running")
    return fd


def read_source(oldest):
    # TODO: replace with the real source read. Must return a list of
    # message dicts, newest first. Pass `oldest` (the last-seen cursor)
    # so most polls return zero messages; pass None when there is no
    # cursor yet. Keep the call's timeout at or below CALL_TIMEOUT.
    # Raise on failure — the caller handles backoff. Raise SourceError with
    # the HTTP status (SourceError(msg, status=resp.status)) so
    # is_auth_error can recognize auth failures.
    raise NotImplementedError("fill in read_source for this poller")


def is_new(m, last_seen):
    # TODO: replace with the source's filter. Production examples:
    #   Slack: skip subtype messages and the bot's own messages.
    #   Discord: skip the bot's own messages; require a mention of the bot.
    # A default of `ts > last_seen` alone is unsafe — it queues the bot's
    # own replies as new work.
    raise NotImplementedError("fill in is_new for this poller")


def is_auth_error(e):
    # Return True when the exception is an auth/permanent failure (an
    # expired or revoked credential) — the daemon exits non-zero on those
    # instead of retrying forever. Decide on the status, never on
    # substrings of the message (ids, timestamps and URLs contain "401").
    # Add 403 here only where the source documents it as an auth failure;
    # many APIs use 403 for rate limits or missing access to one resource.
    return getattr(e, "status", None) == 401


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
    lock_fd = take_daemon_lock()
    # A fresh start clears any error marker from a previous run.
    if os.path.exists(ERROR_FILE):
        os.unlink(ERROR_FILE)
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
                    log(f"queued {len(new)} new item(s), latest ts {last_seen}")
            # Heartbeat on every successful poll, even a quiet one.
            save_last_seen(last_seen)
            consecutive_failures = 0
        except Exception as e:
            consecutive_failures += 1
            log(f"poll error ({consecutive_failures} in a row): {e}")
            if is_auth_error(e):
                # A permanent failure (expired/revoked credential) will
                # never succeed by retrying. Mark it and exit non-zero so
                # the worker's liveness check notices instead of the
                # daemon sitting in `ps` looking alive while nothing is
                # ever queued.
                write_error("auth", e)
                log("auth error — exiting (check the credential)")
                raise SystemExit(1)
            if consecutive_failures >= MAX_FAILURES:
                write_error("consecutive_failures", e)
                log(f"{MAX_FAILURES} consecutive failures — exiting")
                raise SystemExit(1)
        elapsed = time.time() - start
        if elapsed > SLOW_CALL_SECS:
            log(f"slow poll: {elapsed:.1f}s (source slow — watch rate limits)")
        if consecutive_failures > 0:
            # Backoff applies only after a failure, and the first failure
            # sleeps BACKOFF_STEPS[0] (not the last step — the off-by-one
            # that made the first failure sleep at the cap).
            step = BACKOFF_STEPS[min(consecutive_failures - 1,
                                     len(BACKOFF_STEPS) - 1)]
            sleep_s = max(POLL_SECS, step)
        else:
            sleep_s = POLL_SECS
        sleep_s += random.uniform(-1, 1) * POLL_JITTER_SECS
        time.sleep(max(5, sleep_s))


if __name__ == "__main__":
    main()
