#!/usr/bin/env python3
"""Tier 1 poller daemon (Python) - a runnable module, not a snippet.

Copy this file, `poller.config.example.json` and an adapter module into the
new poller's directory, edit the config, write (or adapt) the adapter, run:

    python3 daemon.py --config poller.config.json      # or POLLER_CONFIG=...

Everything source-specific lives in the adapter; everything operational
(timing, backoff, state files, locks, logs) lives here. The baseline,
backoff, no-overlap and slow-call rules are load-bearing - do not weaken
them when adapting.

Config (JSON; all times in seconds):
  name                 display name used in the start log
  state_dir_name       state dir name under <state_root>/, e.g. "team-queue"
  stop_file_name       stop file name under <state_root>/
  poll_secs            poll interval (10 fast API, 60 slow/quiet API). The
                       worker's poll must match this.
  poll_jitter_secs     jitter on the sleep
  backoff_steps_secs   e.g. [60, 120, 300]; capped, reset on success; the
                       first failure sleeps backoff_steps_secs[0]
  slow_call_secs       slow-call log threshold
  call_timeout_secs    timeout for one source call; must be <= poll_secs so a
                       call can never overlap the next cycle. The adapter
                       enforces it (it receives the config).
  max_failures         consecutive failed polls before giving up (error.json,
                       exit non-zero). An auth error exits immediately.
  channels             [{"id": ..., "name": ...}, ...] - at least one; each
                       has its own cursor
  adapter              dotted module path (imported), or a path ending in
                       ".py" (relative to the config file); must define
                       make_source(config) -> Source
  adapter_options      optional object, free-form, read by the adapter
  state_root           optional, default ~/hooks/state (env POLLER_STATE_ROOT
                       overrides the default)
  queue_lock_wait_secs optional, default 30: how long an append waits for
                       queue.lock before the poll counts as failed

Adapter contract (see `Source`): fetch(channel, since) returns items newest
first; `since` is the channel cursor, or None when there is none yet (return
recent items unfiltered - the daemon baselines from them and queues none).
Raise SourceError(msg, status=...) on failure; rate-limit retry (prompt,
`retry_after` seconds) lives in the adapter, failure backoff (minutes) lives
here. Auth is judged on `status == 401` only, never on message text (ids,
timestamps and URLs contain "401"). Extend is_auth_error with 403 only where
the source documents it as an auth failure.

Credentials: read the source token from the environment or a secrets store
inside the adapter - never hard-code it, never commit it, keep it out of
logs and queue lines. An expired or revoked credential raises a 401
SourceError and the daemon exits non-zero rather than retrying forever.

Logs: one JSON object per line on stderr:
  {"ts": ISO-8601 UTC, "level": "info|warn|error", "event": "...", ...}
Never put message text or usernames in log fields; queue lines hold content.

Queue appends: every append to queue.jsonl happens while holding an
exclusive flock on <state_dir>/queue.lock, and opens the queue by path for
each batch (open, append, fsync, close) so a rename by a rotator is picked
up on the next batch.

Starting the daemon: a supervised service (systemd, launchd) is fine in
normal environments. Only where network credentials are scoped to an
agent's tool call (for example an egress-proxy credential that rotates per
call) must the daemon be started from agent context (a tool call, a cron,
or a hook), because a service cannot hold a current credential there. A
long-running daemon keeps working on the credential it started with; in
such environments, recovery after the host is replaced needs an
agent-context mechanism.
"""
from __future__ import annotations

import argparse
import fcntl
import importlib
import importlib.util
import json
import os
import random
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Protocol

Item = dict[str, Any]


class SourceError(Exception):
    """Raised by an adapter on a failed call. `status` is the HTTP-like
    status (or None) so auth is decided on the status, not on message text."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class ConfigError(Exception):
    """The config file is missing, malformed or invalid."""


@dataclass(frozen=True)
class Channel:
    id: str
    name: str


@dataclass(frozen=True)
class Config:
    name: str
    state_dir_name: str
    stop_file_name: str
    poll_secs: float
    poll_jitter_secs: float
    backoff_steps_secs: list[float]
    slow_call_secs: float
    call_timeout_secs: float
    max_failures: int
    channels: list[Channel]
    adapter: str
    adapter_options: dict[str, Any] = field(default_factory=dict)
    state_root: str = ""
    queue_lock_wait_secs: float = 30.0
    base_dir: str = "."

    @property
    def state_dir(self) -> str:
        return os.path.join(self.state_root, self.state_dir_name)

    @property
    def stop_file(self) -> str:
        return os.path.join(self.state_root, self.stop_file_name)


class Source(Protocol):
    """The source adapter. Items are dicts; the daemon never looks inside
    them except through these methods."""

    def fetch(self, channel: Channel, since: str | None) -> list[Item]:
        """Return recent items, newest first. `since` is the channel cursor
        (None = no cursor yet: return recent items unfiltered). Raise
        SourceError on failure."""
        ...

    def is_new(self, item: Item, since: str | None) -> bool:
        """Which items count as queue items. Filter the bot's own items and
        any system items. `ts > since` alone is unsafe: it queues the bot's
        own replies as new work."""
        ...

    def cursor_of(self, item: Item) -> str:
        """The cursor value that marks this item as seen."""
        ...

    def to_queue_item(self, channel: Channel, item: Item) -> Item:
        """The JSONL line per item. Include every field the worker's
        decision rules need (who it is for, channel, author, timestamp,
        thread state) - a minimal shape forces a re-fetch per item."""
        ...


# --------------------------------------------------------------------------
# Config

def _number(d: dict[str, Any], key: str, minimum: float = 0.0, allow_equal: bool = False) -> float:
    v = d.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ConfigError(f"config: {key} must be a number")
    if v < minimum or (v == minimum and not allow_equal):
        raise ConfigError(f"config: {key} must be {'>=' if allow_equal else '>'} {minimum}")
    return float(v)


def _plain_name(d: dict[str, Any], key: str) -> str:
    v = d.get(key)
    if not isinstance(v, str) or not v or "/" in v or v in (".", ".."):
        raise ConfigError(f"config: {key} must be a non-empty name without slashes")
    return v


def parse_config(raw: Any, base_dir: str = ".") -> Config:
    if not isinstance(raw, dict):
        raise ConfigError("config: top level must be a JSON object")
    name = raw.get("name")
    if not isinstance(name, str) or not name:
        raise ConfigError("config: name must be a non-empty string")
    poll = _number(raw, "poll_secs")
    jitter = _number(raw, "poll_jitter_secs", 0.0, allow_equal=True)
    slow = _number(raw, "slow_call_secs")
    timeout = _number(raw, "call_timeout_secs")
    if timeout > poll:
        raise ConfigError(
            "config: call_timeout_secs must be <= poll_secs (a call must not overlap the next cycle)")
    steps = raw.get("backoff_steps_secs")
    if (not isinstance(steps, list) or not steps
            or any(isinstance(s, bool) or not isinstance(s, (int, float)) or s <= 0 for s in steps)):
        raise ConfigError("config: backoff_steps_secs must be a non-empty list of positive numbers")
    max_failures = raw.get("max_failures")
    if isinstance(max_failures, bool) or not isinstance(max_failures, int) or max_failures < 1:
        raise ConfigError("config: max_failures must be an integer >= 1")
    chans = raw.get("channels")
    if not isinstance(chans, list) or not chans:
        raise ConfigError("config: channels must be a non-empty list of {id, name}")
    channels: list[Channel] = []
    for c in chans:
        if (not isinstance(c, dict) or not isinstance(c.get("id"), str) or not c["id"]
                or not isinstance(c.get("name"), str) or not c["name"]):
            raise ConfigError("config: each channel needs a non-empty string id and name")
        channels.append(Channel(c["id"], c["name"]))
    if len({c.id for c in channels}) != len(channels):
        raise ConfigError("config: channel ids must be unique")
    adapter = raw.get("adapter")
    if not isinstance(adapter, str) or not adapter:
        raise ConfigError("config: adapter must be a module path string")
    options = raw.get("adapter_options", {})
    if not isinstance(options, dict):
        raise ConfigError("config: adapter_options must be an object")
    root = raw.get("state_root")
    if root is not None and (not isinstance(root, str) or not root):
        raise ConfigError("config: state_root must be a non-empty string")
    if root is None:
        root = os.environ.get("POLLER_STATE_ROOT") or "~/hooks/state"
    wait = _number(raw, "queue_lock_wait_secs") if "queue_lock_wait_secs" in raw else 30.0
    return Config(
        name=name,
        state_dir_name=_plain_name(raw, "state_dir_name"),
        stop_file_name=_plain_name(raw, "stop_file_name"),
        poll_secs=poll,
        poll_jitter_secs=jitter,
        backoff_steps_secs=[float(s) for s in steps],
        slow_call_secs=slow,
        call_timeout_secs=timeout,
        max_failures=max_failures,
        channels=channels,
        adapter=adapter,
        adapter_options=options,
        state_root=os.path.expanduser(root),
        queue_lock_wait_secs=wait,
        base_dir=base_dir,
    )


def load_config(path: str) -> Config:
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        raise ConfigError(f"config: file not found: {path}") from None
    except json.JSONDecodeError as e:
        raise ConfigError(f"config: invalid JSON in {path}: {e}") from None
    return parse_config(raw, os.path.dirname(os.path.abspath(path)))


def load_source(config: Config) -> Source:
    name = config.adapter
    try:
        if name.endswith(".py"):
            path = name if os.path.isabs(name) else os.path.join(config.base_dir, name)
            spec = importlib.util.spec_from_file_location("poller_adapter", path)
            if spec is None or spec.loader is None:
                raise ImportError(f"cannot load {path}")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        else:
            if config.base_dir not in sys.path:
                sys.path.insert(0, config.base_dir)
            mod = importlib.import_module(name)
    except (ImportError, OSError) as e:
        raise ConfigError(f"config: cannot import adapter {name!r}: {e}") from None
    factory = getattr(mod, "make_source", None)
    if not callable(factory):
        raise ConfigError(f"config: adapter {name!r} does not define make_source(config)")
    return factory(config)  # type: ignore[no-any-return]


# --------------------------------------------------------------------------
# Logging, state files, locks

def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(level: str, event: str, **fields: Any) -> None:
    rec = {"ts": _now(), "level": level, "event": event, **fields}
    print(json.dumps(rec, default=str), file=sys.stderr, flush=True)


def atomic_write_json(path: str, obj: Any) -> None:
    # Temp file in the same directory, fsync, then replace - so a crash or
    # kill mid-write never leaves a truncated state file.
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(obj, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load_last_seen(path: str, first_channel_id: str) -> dict[str, str]:
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    if not isinstance(data, dict):
        return {}
    chans = data.get("channels")
    if isinstance(chans, dict):
        return {str(k): str(v) for k, v in chans.items()}
    legacy = data.get("ts")  # old single-cursor format
    if legacy and legacy != "0":
        return {first_channel_id: str(legacy)}
    return {}


def save_last_seen(config: Config, cursors: dict[str, str]) -> None:
    # Heartbeat: written on EVERY successful poll, not only when items were
    # queued. The worker's liveness check reads `polled_at` - stale past the
    # worker's threshold (poll interval + first backoff step + call timeout)
    # means the daemon is dead, even on a quiet source. Never call this
    # after a failed poll.
    os.makedirs(config.state_dir, exist_ok=True)
    atomic_write_json(os.path.join(config.state_dir, "last-seen.json"),
                      {"channels": cursors, "polled_at": _now()})


def write_error(config: Config, kind: str, detail: Any) -> None:
    # Error marker the worker's liveness check reads. Written when the
    # daemon gives up before it exits non-zero; removed on the next start.
    os.makedirs(config.state_dir, exist_ok=True)
    atomic_write_json(os.path.join(config.state_dir, "error.json"),
                      {"kind": kind, "detail": str(detail)[:500], "at": _now()})


def take_daemon_lock(config: Config) -> int:
    # Only one daemon instance may run: two share the cursors and append
    # every item twice. Exclusive flock held for the daemon's lifetime
    # (released automatically if the process dies).
    os.makedirs(config.state_dir, exist_ok=True)
    fd = os.open(os.path.join(config.state_dir, "daemon.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        log("error", "already_running", detail="daemon lock held - another instance is running")
        raise SystemExit(1) from None
    return fd


def append_queue(config: Config, lines: list[str]) -> None:
    """Append one batch of JSON lines to queue.jsonl under queue.lock.

    The queue is opened by path for every batch so that a rotator which
    renames queue.jsonl while holding the same lock is picked up."""
    os.makedirs(config.state_dir, exist_ok=True)
    data = "".join(line + "\n" for line in lines).encode()
    lock_fd = os.open(os.path.join(config.state_dir, "queue.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        deadline = time.monotonic() + config.queue_lock_wait_secs
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("queue.lock held too long") from None
                time.sleep(0.02)
        try:
            fd = os.open(os.path.join(config.state_dir, "queue.jsonl"),
                         os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        os.close(lock_fd)


def is_auth_error(e: BaseException) -> bool:
    # Decide on the status, never on substrings of the message.
    return getattr(e, "status", None) == 401


# --------------------------------------------------------------------------
# Polling loop

def poll_once(config: Config, source: Source, cursors: dict[str, str]) -> int:
    """One pass over all channels. Mutates `cursors`; returns items queued.
    Any adapter exception aborts the pass (the caller counts it as a
    failure); cursors already advanced for earlier channels stay advanced."""
    queued = 0
    for ch in config.channels:
        since = cursors.get(ch.id)
        items = source.fetch(ch, since)
        if not items:
            if since is None:
                # An empty first poll must NOT baseline: the next poll
                # would treat the whole recent history as new work.
                log("info", "baseline_empty", channel=ch.name)
            continue
        newest = source.cursor_of(items[0])
        if since is None:
            cursors[ch.id] = newest
            log("info", "baseline", channel=ch.name, cursor=newest, seen=len(items), queued=0)
            continue
        new = [i for i in items if source.is_new(i, since)]
        new.reverse()  # newest-first from the source; queue oldest first
        if new:
            append_queue(config, [json.dumps(source.to_queue_item(ch, i)) for i in new])
            queued += len(new)
            log("info", "queued", channel=ch.name, count=len(new), cursor=newest)
        # Advance only after the batch append succeeded; also moves past
        # trailing filtered items so they are not re-fetched every poll.
        cursors[ch.id] = newest
    return queued


def run(
    config: Config,
    source: Source,
    *,
    max_polls: int | None = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.time,
    uniform: Callable[[float, float], float] = random.uniform,
) -> None:
    """The daemon loop. Returns on stop file or after max_polls; raises
    SystemExit(1) on auth error, give-up or a held daemon lock."""
    lock_fd = take_daemon_lock(config)
    try:
        error_file = os.path.join(config.state_dir, "error.json")
        if os.path.exists(error_file):  # a fresh start clears the old marker
            os.unlink(error_file)
        log("info", "start", name=config.name, poll_secs=config.poll_secs,
            jitter_secs=config.poll_jitter_secs, stop_file=config.stop_file_name,
            channels=[c.name for c in config.channels])
        cursors = load_last_seen(os.path.join(config.state_dir, "last-seen.json"),
                                 config.channels[0].id)
        failures = 0
        polls = 0
        while True:
            if os.path.exists(config.stop_file):
                log("info", "stop", detail="stop file present")
                return
            start = clock()
            backoff: float | None = None
            try:
                queued = poll_once(config, source, cursors)
                # Heartbeat on every successful poll, even a quiet one.
                save_last_seen(config, cursors)
                failures = 0
                elapsed = clock() - start
                log("info", "poll_ok", queued=queued, duration_ms=round(elapsed * 1000))
            except Exception as e:  # noqa: BLE001 - every adapter failure is handled here
                failures += 1
                elapsed = clock() - start
                # First failure sleeps backoff_steps[0], not the cap.
                backoff = config.backoff_steps_secs[min(failures - 1, len(config.backoff_steps_secs) - 1)]
                log("warn", "poll_failed", attempt=failures, max_failures=config.max_failures,
                    backoff_secs=backoff, error=str(e)[:500], status=getattr(e, "status", None))
                if is_auth_error(e):
                    # Permanent: retrying never helps. Mark and exit non-zero
                    # so the liveness check notices.
                    write_error(config, "auth", e)
                    log("error", "auth_error", detail="exiting - check the credential")
                    raise SystemExit(1) from None
                if failures >= config.max_failures:
                    write_error(config, "consecutive_failures", e)
                    log("error", "give_up", failures=failures)
                    raise SystemExit(1) from None
            if elapsed > config.slow_call_secs:
                log("warn", "poll_slow", duration_ms=round(elapsed * 1000),
                    threshold_secs=config.slow_call_secs)
            polls += 1
            if max_polls is not None and polls >= max_polls:
                return
            sleep_s = config.poll_secs if backoff is None else max(config.poll_secs, backoff)
            sleep_s += uniform(-1, 1) * config.poll_jitter_secs
            sleep(max(5.0, sleep_s))
    finally:
        os.close(lock_fd)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description="Tier 1 poller daemon")
    ap.add_argument("--config", default=os.environ.get("POLLER_CONFIG"),
                    help="path to the JSON config (or set POLLER_CONFIG)")
    args = ap.parse_args(argv)
    try:
        if not args.config:
            raise ConfigError("config: pass --config PATH or set POLLER_CONFIG")
        config = load_config(args.config)
        source = load_source(config)
    except ConfigError as e:
        log("error", "config_error", detail=str(e))
        raise SystemExit(2) from None
    run(config, source)


if __name__ == "__main__":
    main()
