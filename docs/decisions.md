# Decisions

Architecture Decision Records for the Subagent Poller SDK. Each entry: the decision, the context, the alternatives considered, and the consequences. Dated 2026-11-13 unless noted.

## ADR-1: Two shapes on one core, not one shape

**Decision.** The SDK carries two shapes — Shape A (two-tier poller) and Shape B (orchestrator) — sharing one core (queue protocol, alive file, worker lock, stop file, rate-limit rules, daemon heartbeat).

**Context.** The pattern started as always-warm workers for live game play (Nov 12). The two-tier form was built the next day for intermittent work (chat mentions, team chat queue). The two forms share the queue protocol and the worker loop but differ in wake-up, lifetime, and routing.

**Alternatives.** (a) One shape only (two-tier), with the orchestrator as a separate pattern — rejected, because the queue protocol, the alive file, the worker lock, the stop file, and the rate-limit rules are identical, and splitting them would duplicate the core. (b) One shape only (orchestrator), with the two-tier form as a degenerate case — rejected, because the hook wake and the idle exit are not degenerate; they are the whole point of the two-tier form.

**Consequences.** The skill is longer (two workflows), but the core is stated once. Shape B is marked proven-by-one; a second orchestrator instance is needed to confirm the generalization.

## ADR-2: A skill, not a library

**Decision.** The SDK is a prompt-only skill with templates — no code library, no CLI, no skill manifest.

**Context.** A poller is a set of behaviors an agent performs, not a program you install. The agent is the runtime.

**Alternatives.** (a) A library with a host process — rejected: it would need a config format, a supervisor, and an operator, for behavior the agent already performs. (b) A CLI (`poller ...`) — rejected: there is no CLI entrypoint to declare, and the templates are the deliverable. A skill manifest is only needed when a runnable command exists.

**Consequences.** The SDK is only usable by an agent that can read the skill and fill the templates. It cannot be installed or run standalone. That is acceptable: the target user is an agent scaffolding a poller, not a human installing a tool.

## ADR-3: The worker poll matches the fastest producer

**Decision.** The worker's poll interval matches the fastest producer of its queue — the daemon for a single-producer queue, the fastest producer (router or sibling worker) for a multi-producer queue.

**Context.** The original rule (Nov 13, owner's words: "Worker poll and daemon poll should always match otherwise it's just wasting cycles") was stated for single-producer queues. The live game session's orchestrator appeared to violate it (workers 5s, router 10s). The refinement came from asking *what produces work in the queue*: the router dispatches at most every 10s, but sibling workers hand off at any moment, so 5s is the right rate for the sibling-handoff producer.

**Alternatives.** (a) Keep the rule as "match the daemon" — rejected, because it would make the live game session's workers poll at 10s and add up to 5s of latency to every sibling handoff (including the narration → voice pipeline). (b) Drop the rule — rejected, because a team's queue worker's original 5s poll against a 60s daemon was 12 checks per possible delivery, 11 of which could find nothing.

**Consequences.** The rule is now per-producer, which is harder to state but correct. The scribe at 15s is the known violation in the other direction (slower than its producers, lags up to 15s) — documented, not fixed.

## ADR-4: The hook prompt is a template, not a one-liner

**Decision.** The wake-time spawner instruction is a full template (`templates/hook-prompt.md`), not a one-line summary.

**Context.** The skill originally suggested "spawn the active worker subagent using the brief at <path>." The production prompts carry five load-bearing requirements. The adversarial review (B3) showed the one-liner drops the most important one: spawn verification. (The fifth requirement — the untrusted-data rule — was added in the 1.0.1 review; see ADR-9.)

**Alternatives.** (a) Keep the one-liner and rely on the worker brief — rejected: the brief is read by the worker, not by the wake-time spawner; the hook prompt is the only instruction the spawner gets. (b) Put the requirements in the skill and reference them — rejected: the prompt must be usable verbatim at registration time, not reconstructed from the skill.

**Consequences.** The skill has one more template to maintain, and the prompt is longer. The gain is that a failed spawn is no longer silent data loss — and, since 1.0.1, a failed spawn is retried once the startup window has passed (cursor-based outstanding, ADR-8) instead of waiting for the next new item.

## ADR-5: Dry-run state 2 is tested by seeding, not by pretending

**Decision.** The skill documents the state-seeding maneuver (write `{"seen_absent": true}` into the hook's state file before dry-running) and the live-run alternative, instead of claiming dry-run covers all five states.

**Context.** A hook dry-run does not persist state, so the "file appears → WAKE" state is unreachable by dry-run alone on a fresh hook (B2). The skill originally prescribed dry-running all three states (a fourth — worker alive — was added in 1.0.1, and a fifth — worker starting — in 1.0.2), which would have led a fresh agent to accept the baseline as correct behavior — the first-canary bug.

**Alternatives.** (a) Change the hook runtime so dry-runs persist state — not ours to change. (b) Drop the five-state dry-run and prescribe live testing only — rejected, because dry-running states 1, 3, and 4 is still useful and safe.

**Consequences.** The skill is honest about what a dry-run can and cannot prove. The seeding step is a manual maneuver that must be documented exactly (the file path and the JSON), which the skill does.

## ADR-6: Daemon health is a required tripwire, not an option

**Decision.** Every worker brief must include a liveness check (daemon process alive + `last-seen.json`'s `polled_at` fresh + no `error.json` marker), and the template makes it required.

**Context.** The skill presented the liveness check as universal while templating it as optional, and a production team-queue brief had none (M7). A poller with no tripwire has a dead daemon go unnoticed until someone checks by hand.

**Alternatives.** (a) Keep it optional — rejected: an optional tripwire is no tripwire, and the team-queue instance proved it (no check at all). (b) Have the hook check daemon health — rejected: the hook's job is to watch the queue, not the daemon; the worker is the one that reads the queue and can check.

**Consequences.** The worker brief template is longer. A production team-queue brief gained a liveness check (Nov 13, unexercised until the next spawn).

## ADR-7: The public copy is sanitized and genericized, not identical

**Decision.** The public repo's copy of the skill sanitizes private identifiers (Discord guild/channel/bot IDs, Slack team/channel/bot IDs, the private server name, the owner's name) to placeholders, and genericizes deployment-specific references (project/bot names, internal ticket IDs, private workspace paths, one deployment's standing-permission terms, a third party's chat handle) to neutral descriptions. The local copies keep the real values.

**Context.** The SDK's value is the templates and the rules, not the instance IDs. The IDs identify the owner's private servers and channels; publishing them adds nothing for a reader and leaks identifiers that need not be public. The project/bot names and ticket IDs are the same shape of leak — they identify one deployment, not the pattern.

**Alternatives.** (a) Publish the local copy verbatim — rejected: the IDs are unnecessary and the server name identifies a private server. (b) Strip the instances file entirely — rejected: the instances are the evidence the templates trace to; a skill without evidence is an assertion.

**Consequences.** The public and local copies diverge on identifiers and deployment-specific references. The divergence is documented here and is limited to the sanitized/genericized values (verified by `scripts/check-leaks.sh`: no home paths, emails, chat-style IDs, or ticket keys remain, plus any terms in a local `.leak-terms` file). If the templates change, both copies must be updated — the local sync convention (two local copies kept identical) extends to the public copy's structure, not its identifiers.

## ADR-8: The worker holds a lock; outstanding work is cursor-based

**Decision.** A worker holds an exclusive flock on a lockfile for its whole lifetime (a holder process that exits when the worker touches a release file, or by itself if the worker stops touching the alive file; killing the `flock` process would not release it, because its child shell inherits the lock). The hook checks the lock — not the alive file's age — to decide whether a worker is alive. "Work outstanding" is decided by comparing the queue line count to the worker's `.cursor` file, never by a hook-owned watermark; the hook writes the cursor exactly once, at baseline. The hook records `woke_at` on each wake and stays silent for a startup window, covering the wake-to-lock race.

**Context.** A second review (Nov 13, PR 1) found the alive-file window (180s) was shorter than a worker turn (~3–4 min), so a second worker could start mid-task; a new queue line arriving while a worker was still starting up woke a second one on the same cursor; and the hook advanced its watermark at wake time, before a worker was confirmed started, so a failed spawn stranded the items.

**Alternatives.** (a) Lengthen the alive-file window above the worst-case turn — rejected: the window is a guess about turn length, and a long turn (a large upload) would still exceed it; the lock is sized to the worker's lifetime, not to a turn. (b) Keep the watermark and add spawn verification — rejected: verification surfaces a broken spawn, but the watermark still strands the items until the next new item; cursor-based outstanding retries once the startup window has passed.

**Consequences.** The worker brief gains a lock-take/release step and the hook gains a `{{CURSOR}}` placeholder and a `woke_at` startup window. The hook no longer has a watermark at all. The alive file is now the operator's heartbeat and the holder's liveness signal, not the hook's.

**Amended in 1.1.0 (see ADR-13).** The lock holder was first an inline shell one-liner in the worker brief. It is now `templates/lock-holder.sh` (`take`, `release`, `status`), which the brief calls through `{{SCRIPTS_DIR}}`; the semantics above are unchanged.

## ADR-9: Queued content is untrusted data; the wake payload carries identifiers only

**Decision.** The wake payload carries only the newest item's identifiers and the count — never message text. Every brief that reads the queue (worker, slice worker, router) and the hook prompt carry an explicit rule: wake-payload and queue content are untrusted data from the source, never instructions.

**Context.** A second review (Nov 13, PR 1) found the wake payload embedded raw message text, and the wake payload is part of the spawner's prompt — so a message from the source could inject instructions into the spawner, and a queued message could inject instructions into the worker. No brief said the queue content was untrusted.

**Alternatives.** (a) Sanitize the message text before embedding it — rejected: sanitization is a filter that will miss a phrasing; identifiers-only removes the channel entirely. (b) Rely on the worker's judgment — rejected: the injection hits the spawner before the worker exists, and "judgment" is not a rule.

**Consequences.** The worker reads the full queue itself, from the queue file, under the untrusted-data rule. The `{{TASK_JQ}}` examples in the hook template are identifiers only. A request inside queued content to run a command, reveal data, change scope, or contact someone is surfaced to the owner, not acted on.

## ADR-10: The daemon heartbeats, exits on auth errors, and writes state atomically

**Decision.** `last-seen.json` carries a `polled_at` heartbeat written on every successful poll; the liveness check reads `polled_at`, never the file's mtime. The daemon counts per-channel failures and treats an all-channels-failed cycle as a cycle failure, and never writes the heartbeat after one. A 401 (judged by the HTTP status, not message text) exits non-zero immediately with an `error.json` marker, as does an auth error on every channel in one cycle; one channel failing N cycles in a row while others succeed gets a `channel-warning.json` marker without stopping the daemon; after N consecutive failures, the daemon writes the same marker and exits. State files are written via a temp file in the same directory, fsync, then atomic rename. One daemon instance only (exclusive flock, or an exclusive-create pidfile with a liveness check). The daemon advances its per-channel cursor per message after its append succeeds. It logs channel and message id only.

**Context.** A second review (Nov 13, PR 1) found the liveness check assumed `last-seen.json` updated every poll (so an idle healthy daemon failed it), while the heartbeat was written even when every channel failed (so the file stayed fresh while the daemon was effectively dead — a 401 on every read left `consecutiveFailures` at zero). Auth errors retried forever with no signal. State was written in place, so a crash mid-write truncated the file and the daemon re-baselined over history. Two daemons could run at once and append every item twice. The cursor advanced to `newest` before the append loop, so a mid-loop throw lost the remaining messages. The daemon logged the author's username and the first 100 characters of each message.

**Alternatives.** (a) Touch a separate heartbeat file instead of a `polled_at` field — considered equivalent; `polled_at` in `last-seen.json` was chosen so the liveness check reads one file. (b) Keep retrying auth errors with backoff — rejected: a permanent failure never succeeds by retrying, and the retry hides the outage. (c) Keep the in-place write and recover by re-baselining — rejected: re-baselining over history is silent data loss.

**Consequences.** The daemons gain an `error.json` marker and a `max_failures` setting (a config key since 1.1.0, previously a `{{MAX_FAILURES}}` placeholder). `last-seen.json` becomes `{channels: {...}, polled_at: ...}` in both daemons (the loaders accept the older formats). The usage skill's health check reads `polled_at` and the error marker. Credentials are read from the environment or a secrets store — never hard-coded or committed, kept out of logs and queue lines, expiry handled as an auth error.

## ADR-11: Where the daemon starts depends on how credentials are scoped

**Decision.** A supervised service (systemd, launchd) is fine in normal environments. Only where network credentials are scoped to an agent's tool call must the daemon be started from agent context (a tool call, a cron, or a hook).

**Context.** In one hosting environment an egress-proxy credential rotates per tool call, so a service cannot hold a current credential and its daemons fail to reach the network. A long-running daemon keeps working on the credential it started with. The constraint comes from that environment, not from the pattern.

**Alternatives.** (a) A service with a credential-refreshing wrapper — rejected in that environment: there is no stable source for the wrapper to read. (b) Bake a long-lived credential into the unit — rejected: it would be a committed secret and would still expire.

**Consequences.** In such environments, recovery after the host is replaced needs an agent-context mechanism (a watchdog hook). The SDK documents the constraint, scoped to those environments, in the skill and in both daemon templates.

## ADR-12: Daemons are modules with a source adapter and a JSON config

**Decision.** `daemon.py` and `daemon.ts` are runnable modules that are copied unchanged. Source-specific code lives in an adapter implementing a four-method `Source` interface (`fetch`, `is_new`, `cursor_of`, `to_queue_item`, with `SourceError(msg, status)` for failures). Operational settings live in a JSON config file selected with `--config` or `POLLER_CONFIG`. TS timing config is in seconds, and the TS `QUEUE_NAME` setting is gone (the queue is `queue.jsonl`).

**Context.** Through 1.0.2 the daemons were templates with `{{...}}` placeholders edited in place. Each poller forked the loop, so the load-bearing rules (baseline, backoff, no-overlap, atomic writes, auth exit) drifted per copy, and nothing could be tested without filling a template first.

**Alternatives.** (a) Keep templates and add tests that fill them first — rejected: the tests would exercise a filled copy, not what ships. (b) A plugin framework with discovery and lifecycle hooks — rejected: four methods and a dotted path or relative path are enough. (c) Environment variables instead of a file — rejected: nested settings (channels, backoff steps, adapter options) need structure, and a file is reviewable.

**Consequences.** Daemon logic has pytest and bun tests (`tests/daemon`). Reviewing a new poller means reading the adapter and the config. Breaking for pollers built from 1.0.x: the placeholders become config keys, TS timing moves from milliseconds to seconds, `QUEUE_NAME` is removed, and the Python `last-seen.json` changes shape (see `CHANGELOG.md`).

## ADR-13: Lock script, queue lock and rotation

**Decision.** The worker lock is `templates/lock-holder.sh` (`take`, `release`, `status`). Every append to a queue holds an exclusive `flock` on `queue.lock` in the queue's directory. `templates/rotate-queue.sh` archives a fully consumed queue under that lock, resets the cursor to 0, and keeps the newest N archives. The hook reads line count and cursor under a non-blocking shared `flock` on `queue.lock` and treats `cursor > lines` or a non-numeric cursor as 0. Mechanisms: `docs/design.md`, "Queue protocol" and "Worker lock".

**Context.** The lock holder was an inline one-liner in the worker brief, copied and hand-edited per poller, and the queue grew without bound because there was no safe way to archive it: a rotation racing an append would lose a line.

**Alternatives.** (a) Keep the inline one-liner — rejected: it could not be tested or shellchecked, and its release path (killing `flock`) was the 1.0.2 bug. (b) Rotate without a lock and rely on timing — rejected: a lost line is silent data loss. (c) Make the hook block on the lock — rejected: a blocked hook delays every other poll; skipping one poll as "queue busy" costs a minute.

**Consequences.** Producers must append under the lock (the daemons do; the router and slice briefs say so). `flock(1)` is now needed by the TS daemon, rotation and the hook's read. Briefs gain `{{SCRIPTS_DIR}}`. The scripts are covered by `tests/hook/run.sh` and shellcheck.

## ADR-14: Daemon and script logs are JSON lines on stderr

**Decision.** Daemons and the two scripts log one JSON object per line on stderr: `{"ts", "level", "event", ...}`. Fields carry channel and item ids only, never message text or usernames.

**Context.** The daemons logged free-form lines, so the operator's health check grepped prose ("baseline at ts ...") and a format tweak broke it; the 1.0.1 privacy fix had to audit every format string.

**Alternatives.** (a) Keep prose logs — rejected for the reasons above. (b) A logging library — rejected: the daemons are standard-library only.

**Consequences.** Logs are filterable with `jq`. Anything that grepped the old prose lines must match on `event` names instead (for example `baseline`).

## ADR-15: One watchdog supervises all daemons

**Decision.** Daemon supervision is one hook (`daemon-watchdog.sh`, 60s poll) reading one registry (`daemon-registry.json`): one entry per daemon with its pgrep pattern, heartbeat file, stale threshold, stop file and start command. It wakes a worker only when a daemon is down, only once per cooldown per daemon, and never for a daemon whose stop file exists. The worker re-checks the stop file and `pgrep` immediately before starting.

**Context.** A host replacement killed both production daemons silently (no traceback, no stop file) and cancelled a worker mid-task. The recovery in place was an hourly cron, which spends a full agent turn per check and takes up to an hour to notice an outage. A systemd service cannot be the recovery mechanism where credentials rotate per tool call (ADR-11). The production watchdog (one hook, two hard-coded daemons, 10-minute per-daemon cooldown) proved the shape twice in one day — a deliberate kill test and the real deployment — so the template generalizes it with a registry instead of hard-coding.

**Alternatives.** (a) One watchdog hook per daemon — rejected: N hooks share no cooldown state and would double-wake for the same down daemon. (b) Keep the recovery cron — rejected: a full turn per check, up to an hour to notice. (c) Have the wake hook check the stop file and restart the daemon itself — rejected: the wake hook's job is waking workers for queue items, and a restart is a worker's job (it needs a fresh agent context to hold the credential).

**Consequences.** The watchdog is the recovery mechanism; the hourly recovery cron is removed. The registry is the single list of supervised daemons — adding a daemon means adding an entry, not a hook. The registry carries the start commands (each entry's `start` field) and the worker brief for the watchdog (`watchdog-worker-brief.md`) tells the worker to read them from it, so the registry is owner-written config and the wake payload stays identifiers-only. The brief branches on the wake reason: a missing process is started once (never a second copy), a hung one (stale or missing heartbeat) is terminated, confirmed gone, then started. To keep a daemon that cannot recover (`error.json`: auth error or `max_failures`) from costing an agent turn every cooldown forever, the hook counts consecutive wakes per daemon in its state and goes silent with an explicit reason after `MAX_CONSECUTIVE_WAKES` (default 3, overridable); the count resets when the daemon is seen healthy or intentionally stopped.

## ADR-16: Transparency is a decision at the resolve gate

**Decision.** Every hook-spawned (Shape A) worker brief carries a RESOLVE instruction (`{{RESOLVE_MODE}}`: `always` / `on-unexpected`), and the worker's exit report ends in a verdict line (ACTED / UNEXPECTED / FAILED / ROUTINE). The poller hook prompt confirms the brief carries the instruction and resolves the verdict line: surface the report unless it is ROUTINE and the mode is `on-unexpected`. The watchdog worker resolves its own report the same way — its hook's prompt is the brief, so there is no separate spawner. Relayed handoffs go to one persistent side chat per poller, which posts them visibly and stays silent otherwise.

**Context.** Two transparency probes looked like delivery failures and were not: the workers ran the check and chose silence because "daemons stopped as intended" is the expected state. The failure mode that is real is the opposite one — a handoff that arrives with a post request buried inside it is not followed, while a direct instruction to post is. The resolve decision therefore has to be explicit in two places (the brief names how the worker's report resolves; the hook prompt names how the spawner resolves the verdict), and the visible post has to go through one persistent side chat per poller.

**Alternatives.** (a) Report every run — rejected: a quiet poller would spam the owner with "still fine" every time a worker exits. (b) Leave the resolve decision to the worker's judgment with no verdict line — rejected: the spawner then has no mechanical rule, and "should I surface this" becomes a judgment call made fresh every run. (c) Post directly from the worker — rejected: hook workers have no chat-send tool; the relay through main into a side chat is the deterministic route.

**Consequences.** Routine silence is the correct default, not a bug. A poller whose owner is waiting (a test, a canary, a live session) sets `always`; everything else runs `on-unexpected`. The activity side chat is the feed the owner reads.
