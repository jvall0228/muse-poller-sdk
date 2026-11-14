# Changelog

## 1.2.0 — 2026-11-13

One watchdog supervises all daemons, and transparency is a decision at the resolve gate.

### Added

- **Daemon supervision templates** (`daemon-watchdog.sh`, `watchdog-worker-brief.md`, `daemon-registry.example.json`): one hook (60s poll) reads a registry of daemons and wakes a worker only when a daemon is down — process alive (anchored `pgrep`) and heartbeat fresh (`polled_at`). It never restarts an intentionally stopped daemon, and wakes only once per cooldown per daemon; the worker re-checks the stop file and `pgrep` before starting so a restart that already happened is not duplicated. The watchdog replaces the recovery cron (ADR-15).
- **Transparency: the resolve gate.** Both worker briefs gain `{{RESOLVE_MODE}}` (`always` / `on-unexpected`, default) and a "Reporting (resolve)" section: the exit report ends in a verdict line (ACTED / UNEXPECTED / FAILED / ROUTINE). The hook prompt's load-bearing requirements are now six: the worker brief carries a RESOLVE instruction, and the spawner confirms it is there and resolves the verdict line. One persistent side chat per poller relays handoffs visibly (ADR-16).
- **Hook tests for the watchdog.** `tests/hook/run.sh` exercises the watchdog's eight dry-run states and its config-error, clock-skew, backoff and brief-reason edge cases against the stub runtime.

### Fixed (watchdog hardening)

- A flapping daemon (polls once, then dies) can no longer be woken forever: the wake count and cooldown reset only after the daemon has stayed healthy for a full cooldown since its last wake, so `MAX_CONSECUTIVE_WAKES` trips.
- `polled_at` validation is strict: an empty file, `null`/`false`/non-scalar values, epoch milliseconds and far-future timestamps are `unparseable`, not healthy; only a missing key is process-only. A leading-zero digit string no longer aborts the poll. A `.waking` value that is fractional, exponent-form or in the future no longer pins a daemon in cooldown.
- A live daemon backing off during a source outage is no longer killed. The registry gains `log_file`; the watchdog stays silent (and says "backing off") when the log ends in a recent `poll_failed`, and the worker brief tells the worker not to kill in that case.

### Changed

- **Recovery is a watchdog hook, not a cron.** The skill's Start-location rule, design.md's start-location rule and ADR-11 now say watchdog hook; the recovery cron is removed.
- **Requirements:** the watchdog script needs `pgrep(1)` and `jq` (checked at startup; a missing one ends the poll silently with the reason). It parses `polled_at` in `jq`, so GNU `date` is not required and it runs on stock macOS; the worker brief detaches a restart with a portable `python3` wrapper instead of `setsid`.
- The review guide's template-fidelity check now covers the watchdog templates and the resolve section.

## 1.1.0 — 2026-11-13

The daemons become tested modules, the worker lock and queue rotation become scripts, and the repo gains tests, a leak check and CI.

### Breaking (pollers built from 1.0.x)

- **A config file replaces the daemon placeholders.** `daemon.py` and `daemon.ts` no longer contain `{{...}}` placeholders. Timing, channels, backoff, `max_failures`, state names and the adapter are keys in a JSON config passed with `--config` or `POLLER_CONFIG`. Invalid config exits 2.
- **TS timing config is in seconds, not milliseconds.** All times in both configs are seconds.
- **`QUEUE_NAME` is removed from the TS daemon.** The queue is always `queue.jsonl`.
- **`last-seen.json` has one shape.** The Python daemon writes `{"channels": {"<id>": "<cursor>"}, "polled_at": ...}`, like the TS daemon. The old `{"ts", "polled_at"}` still loads. A channel's cursor moves only after that channel's whole batch is appended.
- **`{{SCRIPTS_DIR}}` in the briefs.** Worker, router and slice-worker briefs call `lock-holder.sh` and `rotate-queue.sh` through this new placeholder; copy the scripts next to the briefs.
- **Producers append under `flock -x queue.lock`.** Any custom producer (router, handoffs, other writers) must take the lock around every append, or a rotation can drop its line.
- **Logs are JSON lines on stderr** (`{"ts","level","event",...}`). Anything that matched the old prose log lines must match `event` names.

### Added

- **Source adapter interface** (`fetch`, `is_new`/`isNew`, `cursor_of`/`cursorOf`, `to_queue_item`/`toQueueItem`, `SourceError(msg, status)`; auth is status 401) with example HTTP adapters, example configs and a strict `tsconfig.json` for the TS daemon.
- **`templates/lock-holder.sh`** (`take`, `release`, `status`) replacing the inline lock one-liner in the worker brief.
- **`templates/rotate-queue.sh`**: archives a fully consumed queue under `queue.lock`, resets the cursor to 0, keeps the newest N archives.
- **Hook:** reads the line count and cursor under a non-blocking shared `flock` on `queue.lock` (silent "queue busy" if held) and treats `cursor > lines` or a non-numeric cursor as 0.
- **Tests:** `tests/daemon` (pytest and `bun test`) and `tests/hook/run.sh` (plain bash, stub runtime).
- **`scripts/check-leaks.sh`** and **`.github/workflows/ci.yml`** (shellcheck, ruff, pytest, tsc strict, bun test, hook tests, leak check), plus a `.gitignore`.
- **Requirements:** `flock(1)` is now also needed by the TS daemon (it spawns it for appends) and by rotation; Python 3.10+ or bun.

### Changed

- **Docs single-sourced.** Mechanisms live in `docs/design.md`, the build contract in the SDK `SKILL.md`, operating in the usage `SKILL.md`, requirements and test commands in the `README.md`; other files link instead of restating. New ADR-12 (adapter and config), ADR-13 (lock script, queue lock, rotation) and ADR-14 (JSON logs); ADR-8 and ADR-10 amended.
- The review guide's template-fidelity check now covers the daemons as modules (loop logic, not filled-in values).

## 1.0.2

Review follow-up. Template-only changes: pollers built from earlier versions need the same edits to benefit.

### Fixed

- **Worker lock release.** Killing the `flock` process left its child shell holding the lock. The holder now exits when a `.release` file appears (or when the alive file goes stale), and release means touching that file and waiting for the lock to free. The take is retried up to 3 times, 1s apart, because the hook's momentary lock probe can collide with it. Exercised with a scratch test: second take fails while held, explicit release frees the lock within seconds, a stale alive file frees it.
- **`flock(1)` required.** The hook now stays silent with an install hint when `flock` is missing (instead of misreading the lock and looping on spawns), the worker brief exits and reports, and the README lists the requirement and no longer claims full portability.
- **Auth detection by status.** Both daemons no longer match "401"/"403" in message text (ids, timestamps and URLs contain them; some APIs use 403 for rate limits). `daemon.py` adds `SourceError(status=...)` and `is_auth_error` checks for 401; `daemon.ts` checks `e.status === 401`. 403 is added only where a source documents it as auth.
- **Per-channel handling (TS daemon).** An auth error on one channel no longer exits the daemon: it exits on a 401 or when every channel failed with an auth error. A channel failing `MAX_FAILURES` cycles in a row while others succeed writes a `channel-warning.json` marker naming it and the daemon keeps running (`error.json` stays reserved for "the daemon gave up"). A non-array response counts as a channel failure; an empty array stays a quiet success.
- **Liveness threshold.** "`polled_at` within 2x the poll interval" tripped on one transient failure. The threshold is now poll interval + first backoff step + call timeout, restart is warranted only if the process is dead, `error.json` exists, or `polled_at` is stale past it, and `polled_at` is documented as an ISO-8601 UTC timestamp.
- **Health-check steps.** Merged near-duplicate cursor checks in the usage skill; the alive-file check no longer treats a few minutes of age as a problem.
- **Router rule.** The router routes by event type only and never acts on content; events whose content asks for actions are routed normally and listed as "flagged for owner review" in the stop report.
- **Owner identity.** The worker and slice-worker briefs gain `{{OWNER_ID}}`: the owner is identified only by a verified author id, never by display name or message text.
- **Retry wording.** A failed spawn is retried once `{{STARTUP_WINDOW_SECS}}` has passed, not on the next poll. `{{STARTUP_WINDOW_SECS}}` and `{{LOCK_STALE_SECS}}` are documented in the SDK skill; the dry-run note and hook header gain the fifth state (worker starting).
- **Docs and scoping.** Removed a duplicated rule and retitled the cursor-based one; the template-fidelity rule allows reviewed template-only changes; the worker brief's liveness-check placeholder matches the new threshold; the "never systemd" rule is rescoped to environments where network credentials are scoped to an agent's tool call; deployment-specific details and a skill name that is not shipped were made generic.

## 1.0.1 — 2026-11-13

Second review (25 line comments on draft PR 1, generated by Claude Code and posted by the owner). All 25 addressed.

### Fixed

- **Worker lock (hook alive-window too short).** The alive-file window (180s) was shorter than a worker turn (~3–4 min), so a second worker could start mid-task — and a new queue line arriving while a worker was still starting up woke a second one on the same cursor. The worker now holds an exclusive flock for its whole lifetime (a holder that exits by itself if the worker stops touching the alive file); the hook checks the lock, not the alive file's age. The hook records `woke_at` on each wake and stays silent for a startup window, covering the wake-to-lock race.
- **Cursor-based outstanding (hook watermark stranded failed spawns).** The hook advanced its watermark at wake time, before a worker was confirmed started, so a failed spawn stranded the items. "Work outstanding" is now decided by comparing the queue line count to the worker's `.cursor` file (a new `{{CURSOR}}` placeholder) — never by a hook-owned watermark. A failed spawn is retried on the next poll. The hook writes the cursor exactly once, at baseline.
- **Daemon auth + failure handling.** Auth errors retried forever with no signal, and per-channel errors were swallowed inside `pollOnce`, so `consecutiveFailures` never incremented when every channel failed (e.g. a 401) while `last-seen.json` stayed fresh — the daemon looked healthy while it was down. Both daemons now exit non-zero immediately on an auth error (with an `error.json` marker), exit after N consecutive failures, count per-channel failures, treat an all-channels-failed cycle as a cycle failure, and do not write the heartbeat after one.
- **Heartbeat.** `last-seen.json` was only written when items were queued, and the liveness check assumed it updated every poll — so an idle healthy daemon failed the check. `polled_at` is now written on every successful poll, and the liveness check reads `polled_at`, never the file's mtime.
- **Prompt injection via the wake payload.** The wake payload embedded raw message text, and no brief said the queue content was untrusted. The payload now carries only the newest item's identifiers and the count (`{{TASK_JQ}}` examples are identifiers only), and every brief plus the hook prompt carries an explicit rule that wake-payload and queue content are untrusted data, never instructions.
- **Per-message cursor.** The TS daemon's channel cursor advanced to `newest` before the append loop, so a mid-loop throw lost the remaining messages. It now advances per message after its append succeeds (and past trailing filtered messages after the loop completes).
- **Atomic writes + single instance + credentials.** State was written in place (a crash mid-write truncated the file and the daemon re-baselined over history), nothing prevented two daemon instances, and there was no guidance on where the source credential lives. State writes are now temp + fsync + atomic rename; the daemon takes an exclusive lock at startup (flock, or an exclusive-create pidfile with a liveness check); credentials are read from the environment or a secrets store, never hard-coded or committed, kept out of logs and queue lines.
- **Log privacy, docstring alignment, portability.** The TS daemon logged the author's username and the first 100 characters of each message (now channel + message id only); the Python docstring said `read_source` receives the sentinel `"0"` (it receives `None`) and described `is_new(m)` while the stub takes `(m, last_seen)` (aligned); the hook used `printf '%(%s)T'` (bash 4.2+) and GNU `stat -c %Y` (fails on BSD/macOS) — now `date +%s` with a portable `stat` fallback.
- **Genericization (public copy only).** The public copy identified a third party by chat handle, published one deployment's standing-permission terms, and carried project/bot names, internal ticket IDs, and private workspace paths as examples. The handle is now "a test mention from a server member"; the standing-permission terms are now "acts within the owner's configured scope"; project/bot names, ticket IDs, and private paths are generic placeholders. The review guide's opening line now addresses "anyone reviewing this SDK before adopting it". The local copies keep the real values.
- **Frontmatter.** Both skills now carry YAML frontmatter (`name` + a one-paragraph `description`).
- **README Requirements section.** Shape A depends on a specific hook runtime (`$HATCH_HOOK_RUNTIME` with `hook_state_get`/`hook_state_set`/`silent`/`wake`, `hooks.add`/`dry_run`/`run`), plus bash, `jq`, and bun for the TS daemon. The README now names that runtime and says what a user on another runtime must supply.
- **Daemons start from agent context, not systemd.** Proven Nov 13: the egress proxy credential rotates per tool call, so a systemd service can never hold a current credential. The skill and both daemon templates now document this constraint instead of prescribing systemd for network daemons.

### Verified

- Filled `daemon.py` and `daemon.ts` compile/build and their empty-first-poll, baseline, queueing, heartbeat, auth-exit, and single-instance paths were exercised live.
- Filled `hook-watch.sh` passes `bash -n`; all four states exercised against a stubbed hook runtime (no-file, file-appears → WAKE with an identifiers-only payload, worker-starting, worker-alive, baseline, re-wake after a stale `woke_at`).
- The worker lock holder was exercised (held while the alive file is fresh, second take fails at once, self-releases on staleness).
- The public copy was verified free of deployment-specific references (grep clean). See `docs/verification.md` for the full second-review record.

### Known gaps (updated)

- Shape B is proven by one instance. A second orchestrator-style build is what would confirm the generalization.
- The Discord cold start is unmeasured (owner's two test mentions pending).
- The production watchers' fixes (B1 + N3, and the 1.0.1 template fixes) apply on their next restart — the 1.0.1 fixes are template-only until the production files are updated.
- The team-queue brief's liveness check is unexercised until the next worker spawn.

## 1.0.0 — 2026-11-13

The first public release. Extracted from three live implementations (a live game session, chat mentions, a team chat queue).

### Added

- **The SDK skill** (`local-subagent-poller/`): two shapes on one core — Shape A two-tier poller and Shape B orchestrator — with the pieces, the workflow, the operating rules, the measured latencies, and the output contract.
- **Seven templates**: `daemon.py`, `daemon.ts`, `hook-watch.sh`, `hook-prompt.md`, `worker-brief.md`, `router-brief.md`, `slice-worker-brief.md`.
- **The operator's skill** (`local-subagent-poller-usage/`): start, health-check, stop/resume, troubleshoot a built poller.
- **Documentation for review** (`docs/`): `design.md` (why each rule exists), `verification.md` (adversarial review + fixes + live tests), `review-guide.md` (what to check, known gaps, open questions), `decisions.md` (ADRs).
- **Instances inventory** (`local-subagent-poller/references/instances.md`): the three live implementations and the rate-limit numbers per source.

### Fixed (adversarial review, same day)

- **B1 — Empty-first-poll baseline bug.** The daemon template (and a production team-queue watcher) marked itself baselined even when the first poll returned zero messages, which would have queued the whole recent history as new work. Now it stays unbaselined until its first poll actually sees messages.
- **B2 — Untestable dry-run state.** The skill prescribed dry-running the "file appears → WAKE" hook state, which is unreachable by dry-run alone on a fresh hook. The skill now documents the state-seeding maneuver and the live-run alternative.
- **B3 — Missing hook-prompt template.** Added `templates/hook-prompt.md`, templating the wake-time spawner instruction verbatim from production (including spawn verification).
- **M1–M8 + N1–N8.** Matched-poll reframed as "fastest producer"; stale-item lesson added; `is_new` made a TODO stub; `queue_item` defaults to the fuller shape; Discord daemon template added; canary ordering guarded; daemon-health liveness check made required; daemon start commands added; hook template fully parameterized; timeout rule corrected; backoff off-by-one fixed (template + production team-queue watcher); wake-latency bound corrected; overclaim softened; placeholder ergonomics fixed; stop-file + hook interaction documented; Discord backoff reachability documented; dead imports removed.

### Measured

- Shape A cold start (team chat queue, clean run): post → reply 4m 35s; wake → reply 3m 42s.
- Shape A warm reply (Discord): ~23s end-to-end.
- Shape B (live game session 2): 6 tasks routed, no errors.
- Scratch live test of the templates: canary → hook wake (live) → worker consumed → cursor advanced → no double-wake.

### Known gaps

- Shape B is proven by one instance (a live game session). A second orchestrator-style build is what would confirm the generalization.
- The Discord cold start is unmeasured (owner's two test mentions pending).
- The production team-queue watcher's B1 + N3 fixes apply on its next restart.
- The team-queue brief's liveness check is unexercised until the next worker spawn.
