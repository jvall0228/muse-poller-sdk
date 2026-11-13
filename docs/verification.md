# Verification

How the SDK was verified, what was found, and what is still unproven. Built 2026-11-13; adversarially reviewed the same day.

## Adversarial review

A subagent with no context of the build decisions — just the original request, the skill files, and the production pollers — was asked to try to break the SDK. Verdict: the extraction was mostly faithful (the hook template's logic body is byte-identical to production apart from placeholders, and every latency number checked out), but it found **3 blocking defects**, 8 mediums, and 8 nits. All were fixed the same day. The review's full report is summarized below; the fixes are in the skill.

### Blocking defects (all fixed)

**B1 — Empty-first-poll baseline bug (live correctness bug, inherited verbatim from production).** The daemon template's baseline branch set `baselined = True` even when the first poll returned zero messages, leaving `last_seen` stuck at the `"0"` sentinel. The next poll then treated the whole recent history as new work — and the worker would act on stale history. Production only escaped because the fleet channel had messages at baseline; Discord's watcher avoids it by construction. Fixed in the template *and* in the production fleet watcher (`watcher.py`): the daemon only marks itself baselined when its first poll actually saw messages. Verified by running a filled template against an empty source: it logged "first poll saw no messages — staying unbaselined" and wrote no `last-seen.json`.

**B2 — The prescribed three-state dry-run cannot pass (state 2 is untestable).** The skill prescribed dry-running all three hook states, including "file appears (new) → WAKE." That state is unreachable via `dry_run` on a fresh hook, because `set_state()` is a no-op under dry-run — the seen_absent recording never happens. A fresh agent following the skill would either conclude the template is broken or accept the baseline as correct behavior (exactly the FLEET-0003 bug). Fixed: the skill now documents the state-seeding maneuver (write `{"seen_absent": true}` into the hook's state file before dry-running) and the live-run alternative. Verified with a stubbed hook runtime: state 1 (no file) → silent + `seen_absent` recorded; state 2 (file appears, seeded state, dry-run) → WAKE with the right payload; state 2 unseeded → baselines (proving the seeding step is necessary, not optional); state 3 (no new lines) → silent.

**B3 — No hook-prompt template.** The skill said to register the hook with "the worker-spawn instruction" and the template header suggested a one-liner. The production prompts carry four load-bearing requirements the one-liner drops — most importantly spawn verification (retry once, report failure), because the hook advances its watermark when it wakes, so a failed spawn is silent data loss. Fixed: `templates/hook-prompt.md` now templates the prompt verbatim from the two production prompts, and the skill's Output Contract lists it as a deliverable.

### Mediums (all fixed)

- **M1 — Varisia poll-rate note framed backwards.** The instances file said the workers' 5s differed from the router's 10s "because the router's dispatch rate is the binding constraint" — inverted reasoning. Rewritten as the per-producer rule: match your fastest producer; the 5s rate is justified by sibling handoffs arriving at any moment, and the scribe at 15s is slower than its producers (can lag up to 15s).
- **M2 — FLEET-0002 lesson dropped entirely.** The stale-item rule appeared nowhere in the SDK. Added to the skill's Operating rules and to the worker-brief template's per-task-rules guidance.
- **M3 — `is_new` stub unsafe.** The daemon template shipped a working `is_new` default (`ts > last_seen`) that silently does the wrong thing for most sources (it queues the bot's own replies). Made it a TODO stub with the production filters as commented examples, and added a default hard rule to the worker brief: never act on your own messages.
- **M4 — `queue_item` drops fields production workers use.** The template kept only `{ts, text}`; the fleet worker needs `user` and `reply_count`, the Discord worker needs author/channel fields. The template now defaults to the fuller shape with a note to include every field the worker's decision rules need.
- **M5 — No Discord daemon template.** The skill's Output Contract referenced a Discord shape that did not exist. Added `templates/daemon.ts`, extracted from the production Discord watcher.
- **M6 — Canary-test ordering hazard unguarded.** The skill never said to wait for the baseline log line before posting the canary, nor that the hook must be registered before the daemon starts. Both orderings are now explicit, with the reasons.
- **M7 — No daemon-health tripwire in the two-tier template.** The liveness check was optional and the production fleet brief had none. It is now required in the template, and the production fleet brief gained one.
- **M8 — No daemon start command.** The skill said "start the daemon" with no command, log path, or aliveness check. Added the start commands (nohup + log redirect for Python, bun background process for TS) and how to confirm the daemon is alive.

### Nits (all fixed)

- **N1 — Incomplete noun parameterization.** Three hardcoded strings in the hook template (`"new item(s) left to it"`, payload key `"new_items"`, `"no queue file yet"`) now use `{{ITEM_NOUN}}` / `{{PAYLOAD_KEY}}` / `{{NO_FILE_REASON}}`; the unused `{{HOOK_NAME}}` placeholder was removed from the docs.
- **N2 — Timeout rule contradicted production.** "Keep the call's timeout shorter than POLL_SECS" — production uses timeout = POLL_SECS. The rule is now "timeout ≤ POLL_SECS."
- **N3 — Backoff docs off-by-one.** The first failure used `BACKOFF_STEPS[1]`, not `[0]`. Fixed the indexing in the template and in the production fleet watcher so the first failure sleeps `BACKOFF_STEPS[0]` and the documented sequences are accurate.
- **N4 — Wake-latency bound understated the path.** "Hook wake latency: ≤60s" omitted the daemon's ≤60s. Now "post → wake ≤120s (daemon ≤60s + hook ≤60s)."
- **N5 — Overclaim.** "The templates are the production files" — the worker brief is a synthesis and the daemon template is fleet-only. Now "the templates are extracted from the production files."
- **N6 — Placeholder ergonomics.** `{{LIVENESS_CHECK}}` now has a section header; the placeholder definitions moved to the top of the worker-brief template; `{{POLL_SECS}}` is documented as a bare integer (not `"60s"`).
- **N7 — Stop-file + hook interaction undocumented.** The hook does not check the stop file, so a wake after the stop file is touched spawns a worker that exits immediately. Documented in the skill's pieces table.
- **N8 — Discord backoff effectively unreachable + dead imports.** Per-channel errors are caught inside `pollOnce`, so the outer backoff only fires on whole-cycle failures — documented in the instances file and the TS template. The dead imports (`subprocess`, `sys`) were removed from the Python template.

## Template checks (after the fixes)

- **Filled `daemon.py` compiles** (`python3 -m py_compile`) with sample values, and its empty-first-poll path was exercised live (see B1 above).
- **Filled `hook-watch.sh` passes `bash -n`**, and its three states were exercised against a stubbed hook runtime (see B2 above).
- **Filled `daemon.ts` builds** (`bun build --target=bun`) with a stub fetch module.
- **Both skill copies are identical** (`diff -r` clean between the two local copies).

## Live tests

- **Scratch live test of the SDK templates (Nov 13).** A scratch two-tier poller was built from the templates (hook + worker brief + queue), a canary was posted, and the full path ran unassisted: the hook fired live on the canary, the worker consumed it, the cursor advanced to 1, and the subsequent polls stayed silent (no double-wake). The scratch hook and state were removed after the test.
- **Fleet-queue cold start (Nov 13, FLEET-0004).** Post → reply 4m 35s; wake → reply 3m 42s; daemon 18s, hook 35s. The worker's cold start + model turn + post dominates (~3–4 min).
- **Fleet-queue first canary (Nov 13, FLEET-0003).** Wake → reply 3m 7s; end-to-end 14m 32s only because the baseline bug (seen_absent) held it ~11 min.
- **Discord warm reply (Nov 13).** ~23s end-to-end ("yo" → "yo 👻").

## What is still unproven

- **Shape B is proven by one instance.** The orchestrator shape is extracted from Varisia live play alone. A second orchestrator-style build is what would confirm the generalization. The skill and this repo both say so.
- **Discord cold-start test pending.** The two-tier cold start is measured for Slack (fleet-queue) but not yet for Discord — the owner's two test mentions (one cold, one warm) are still outstanding.
- **The production fleet watcher fix applies on next restart.** The empty-first-poll baseline fix and the backoff off-by-one fix were applied to `watcher.py`, but the running daemon loaded the old code. The fixes take effect when the daemon next restarts. The running daemon is past its first poll and has no consecutive failures, so the fixes are not urgent.
- **The fleet brief's liveness check is new.** The production fleet brief gained a daemon-health liveness check (M7). It only takes effect on the next worker spawn and has not yet been exercised by a live worker.
