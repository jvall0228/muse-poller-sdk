import fcntl
import json
import os
import threading

import daemon
import pytest
from daemon import Config, ConfigError, parse_config, run
from fake_adapter import FakeSource


def make_config(tmp_path, **over):
    raw = {
        "name": "test watcher", "state_dir_name": "s", "stop_file_name": "stop",
        "poll_secs": 60, "poll_jitter_secs": 0, "backoff_steps_secs": [60, 120, 300],
        "slow_call_secs": 10, "call_timeout_secs": 30, "max_failures": 3,
        "channels": [{"id": "c1", "name": "team-queue"}],
        "adapter": "fake_adapter", "adapter_options": {"self_id": "bot"},
        "state_root": str(tmp_path), "queue_lock_wait_secs": 5,
    }
    raw.update(over)
    return parse_config(raw)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def queue_lines(cfg):
    p = os.path.join(cfg.state_dir, "queue.jsonl")
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return [json.loads(line) for line in f]


def test_baseline_then_new_items_queued(tmp_path, capsys):
    cfg = make_config(tmp_path)
    src = FakeSource()
    src.push("c1", "old")
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    assert queue_lines(cfg) == []  # baseline queues nothing
    src.push("c1", "hello")
    src.push("c1", "from bot", author="bot")  # own line filtered
    src.push("c1", "second")
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    lines = queue_lines(cfg)
    assert [x["text"] for x in lines] == ["hello", "second"]  # oldest first
    assert lines[0] == {"id": "2", "channel_id": "c1", "channel_name": "team-queue",
                        "author_id": "alice", "text": "hello"}
    ls = read_json(os.path.join(cfg.state_dir, "last-seen.json"))
    assert ls["channels"] == {"c1": "4"}  # advanced past the filtered tail too


def test_empty_poll_heartbeat_and_unbaselined(tmp_path):
    cfg = make_config(tmp_path)
    src = FakeSource()
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    ls = read_json(os.path.join(cfg.state_dir, "last-seen.json"))
    assert ls["channels"] == {}  # empty first poll stays unbaselined
    assert "polled_at" in ls
    first = ls["polled_at"]
    src.push("c1", "x")
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    assert queue_lines(cfg) == []  # still baselines, not queued
    # quiet poll: cursor unchanged, heartbeat written
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    ls2 = read_json(os.path.join(cfg.state_dir, "last-seen.json"))
    assert ls2["channels"] == {"c1": "1"} and ls2["polled_at"] >= first


def test_backoff_then_give_up(tmp_path, capsys):
    cfg = make_config(tmp_path)
    src = FakeSource()
    src.fail("c1", 500)
    sleeps = []
    with pytest.raises(SystemExit) as ei:
        run(cfg, src, sleep=sleeps.append)
    assert ei.value.code == 1
    assert sleeps == [60, 120]  # first failure sleeps step 0; no sleep after giving up
    err = read_json(os.path.join(cfg.state_dir, "error.json"))
    assert err["kind"] == "consecutive_failures"
    assert not os.path.exists(os.path.join(cfg.state_dir, "last-seen.json"))
    events = [json.loads(x) for x in capsys.readouterr().err.splitlines()]
    failed = [e for e in events if e["event"] == "poll_failed"]
    assert [e["attempt"] for e in failed] == [1, 2, 3]
    assert failed[0]["backoff_secs"] == 60
    assert events[-1]["event"] == "give_up"


def test_backoff_caps_and_resets(tmp_path):
    cfg = make_config(tmp_path, max_failures=10, backoff_steps_secs=[10, 20], poll_secs=5,
                      call_timeout_secs=5)
    src = FakeSource()
    src.fail("c1", 503)
    sleeps = []

    def sleep(s):
        sleeps.append(s)
        if len(sleeps) == 4:
            src.recover("c1")

    run(cfg, src, max_polls=6, sleep=sleep)
    assert sleeps == [10, 20, 20, 20, 5]  # capped, then poll interval after recovery


def test_401_is_auth_error_exits_immediately(tmp_path, capsys):
    cfg = make_config(tmp_path, max_failures=5)
    src = FakeSource()
    src.fail("c1", 401, "token 401 expired")
    with pytest.raises(SystemExit) as ei:
        run(cfg, src, sleep=lambda s: None)
    assert ei.value.code == 1
    assert read_json(os.path.join(cfg.state_dir, "error.json"))["kind"] == "auth"
    assert len(src.calls) == 1
    assert "auth_error" in capsys.readouterr().err


def test_message_text_401_is_not_auth(tmp_path):
    cfg = make_config(tmp_path, max_failures=2)
    src = FakeSource()
    src.fail("c1", 500, "id 401 failed")
    with pytest.raises(SystemExit):
        run(cfg, src, sleep=lambda s: None)
    assert read_json(os.path.join(cfg.state_dir, "error.json"))["kind"] == "consecutive_failures"


def test_second_instance_refused(tmp_path, capsys):
    cfg = make_config(tmp_path)
    os.makedirs(cfg.state_dir)
    fd = os.open(os.path.join(cfg.state_dir, "daemon.lock"), os.O_RDWR | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        with pytest.raises(SystemExit) as ei:
            run(cfg, FakeSource(), max_polls=1, sleep=lambda s: None)
        assert ei.value.code == 1
        assert "already_running" in capsys.readouterr().err
    finally:
        os.close(fd)
    run(cfg, FakeSource(), max_polls=1, sleep=lambda s: None)  # lock released by run


def test_stop_file_ends_loop_cleanly(tmp_path, capsys):
    cfg = make_config(tmp_path)
    src = FakeSource()
    calls = []

    def sleep(s):
        calls.append(s)
        open(cfg.stop_file, "w").close()

    run(cfg, src, sleep=sleep)  # returns, does not raise
    assert len(calls) == 1
    assert '"event": "stop"' in capsys.readouterr().err


def test_start_clears_old_error_marker(tmp_path):
    cfg = make_config(tmp_path)
    os.makedirs(cfg.state_dir)
    with open(os.path.join(cfg.state_dir, "error.json"), "w") as f:
        f.write("{}")
    run(cfg, FakeSource(), max_polls=1, sleep=lambda s: None)
    assert not os.path.exists(os.path.join(cfg.state_dir, "error.json"))


def test_append_waits_for_queue_lock(tmp_path):
    cfg = make_config(tmp_path)
    os.makedirs(cfg.state_dir)
    lock_fd = os.open(os.path.join(cfg.state_dir, "queue.lock"), os.O_RDWR | os.O_CREAT)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    done = threading.Event()

    def appender():
        daemon.append_queue(cfg, ['{"a": 1}'])
        done.set()

    t = threading.Thread(target=appender)
    t.start()
    assert not done.wait(0.4)  # blocked while we hold the lock
    assert queue_lines(cfg) == []
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
    assert done.wait(5)
    t.join()
    assert queue_lines(cfg) == [{"a": 1}]


def test_append_reopens_after_rename(tmp_path):
    cfg = make_config(tmp_path)
    daemon.append_queue(cfg, ['{"n": 1}'])
    q = os.path.join(cfg.state_dir, "queue.jsonl")
    os.rename(q, q + ".archive")  # what the rotator does under the lock
    daemon.append_queue(cfg, ['{"n": 2}'])
    assert queue_lines(cfg) == [{"n": 2}]


def test_append_lock_timeout_counts_as_failure(tmp_path):
    cfg = make_config(tmp_path, queue_lock_wait_secs=0.1, max_failures=1)
    src = FakeSource()
    src.push("c1", "a")
    run(cfg, src, max_polls=1, sleep=lambda s: None)  # baseline
    src.push("c1", "b")
    lock_fd = os.open(os.path.join(cfg.state_dir, "queue.lock"), os.O_RDWR | os.O_CREAT)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        with pytest.raises(SystemExit):
            run(cfg, src, sleep=lambda s: None)
    finally:
        os.close(lock_fd)
    # cursor was not advanced past the unqueued item
    assert read_json(os.path.join(cfg.state_dir, "last-seen.json"))["channels"] == {"c1": "1"}


def test_slow_poll_logged(tmp_path, capsys):
    cfg = make_config(tmp_path)
    ticks = iter([0.0, 12.0, 12.0, 12.0])
    run(cfg, FakeSource(), max_polls=1, sleep=lambda s: None, clock=lambda: next(ticks))
    events = [json.loads(x) for x in capsys.readouterr().err.splitlines()]
    assert any(e["event"] == "poll_slow" and e["level"] == "warn" for e in events)


def test_logs_are_json_lines(tmp_path, capsys):
    cfg = make_config(tmp_path)
    src = FakeSource()
    src.push("c1", "secret text")
    run(cfg, src, max_polls=2, sleep=lambda s: None)
    err = capsys.readouterr().err
    for line in err.splitlines():
        rec = json.loads(line)
        assert rec["level"] in ("info", "warn", "error")
        assert rec["event"] and rec["ts"].endswith("+00:00")
    assert {json.loads(x)["event"] for x in err.splitlines()} >= {"start", "baseline", "poll_ok"}
    assert "secret text" not in err


def test_legacy_last_seen_ts_is_honoured(tmp_path):
    cfg = make_config(tmp_path)
    os.makedirs(cfg.state_dir)
    with open(os.path.join(cfg.state_dir, "last-seen.json"), "w") as f:
        json.dump({"ts": "1", "polled_at": "x"}, f)
    src = FakeSource()
    src.push("c1", "a")
    src.push("c1", "b")
    run(cfg, src, max_polls=1, sleep=lambda s: None)
    assert [x["text"] for x in queue_lines(cfg)] == ["b"]


@pytest.mark.parametrize("patch", [
    {"poll_secs": 0}, {"call_timeout_secs": 90}, {"backoff_steps_secs": []},
    {"max_failures": 0}, {"channels": []}, {"adapter": ""}, {"state_dir_name": "a/b"},
    {"channels": [{"id": "x", "name": "a"}, {"id": "x", "name": "b"}]},
])
def test_config_validation_fails_fast(tmp_path, patch):
    with pytest.raises(ConfigError):
        make_config(tmp_path, **patch)


def test_load_source_from_file_path_and_missing_make_source(tmp_path):
    here = os.path.dirname(os.path.abspath(__file__))
    cfg = make_config(tmp_path, adapter=os.path.join(here, "fake_adapter.py"))
    assert type(daemon.load_source(cfg)).__name__ == "FakeSource"
    (tmp_path / "bad.py").write_text("x = 1\n")
    with pytest.raises(ConfigError):
        daemon.load_source(make_config(tmp_path, adapter=str(tmp_path / "bad.py")))
    with pytest.raises(ConfigError):
        daemon.load_source(make_config(tmp_path, adapter="no_such_module_xyz"))


def test_example_config_parses():
    here = os.path.dirname(os.path.abspath(__file__))
    cfg = daemon.load_config(os.path.join(here, "..", "..", "local-subagent-poller", "templates",
                                          "poller.config.example.json"))
    assert isinstance(cfg, Config) and cfg.adapter == "example_http_adapter"
    assert hasattr(daemon.load_source(cfg), "fetch")


def test_cli_exit_codes(tmp_path):
    import subprocess
    import sys
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                          "local-subagent-poller", "templates", "daemon.py")
    r = subprocess.run([sys.executable, script, "--config", str(tmp_path / "nope.json")],
                       capture_output=True, text=True, timeout=30, check=False)
    assert r.returncode == 2
    assert json.loads(r.stderr.splitlines()[-1])["event"] == "config_error"
