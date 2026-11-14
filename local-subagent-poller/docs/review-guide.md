# Review guide

For anyone reviewing this SDK before adopting it. What to check, in order of importance, and what is already known to be imperfect.

## How to review it

1. **Read the skill first** (`local-subagent-poller/SKILL.md`). It is the build contract: the two shapes, the pieces, the `Source` interface and config schema, the workflow, the operating rules, the output contract.
2. **Read the design doc** (`docs/design.md`) for each mechanism and the failure behind each rule.
3. **Read the verification doc** (`docs/verification.md`) for what was found by adversarial review, and run the checks in the `README.md` ("Running the checks").
4. **Spot-check one template against its production ancestor** (see "Template fidelity" below). Do not trust the skill's claim that every line traces — verify one.
5. **Check the open questions** at the end of this guide and decide whether each is acceptable, needs a fix, or needs a second implementation before adoption.

## What to check

### 1. Template fidelity — does each template trace to production?

Every template line should trace to one of the instances in `local-subagent-poller/references/instances.md`, or to a reviewed template-only change recorded in the CHANGELOG or `docs/decisions.md`. Spot-check:

- `templates/hook-watch.sh` vs the production wake scripts (Discord mentions, Slack fleet-queue). The logic body should match apart from placeholders and the recorded changes. The seen_absent branch, the worker-lock check, and the cursor-based outstanding rule are the load-bearing parts — confirm all three are present and in the right order.
- `templates/daemon.py` and `templates/daemon.ts` are modules with source adapters (since 1.1.0), not templates with placeholders, so fidelity is checked on the loop logic, not on filled-in values, and `tests/daemon` pins it. Against the production watchers (a fleet-queue Python watcher, a discord-mentions TS watcher), confirm: the baseline branch only marks a channel baselined when items were seen; the backoff indexes `consecutive_failures - 1`; a channel's cursor moves only after its whole batch is appended; per-channel failures are counted, an all-channels-failed cycle is a cycle failure and the heartbeat is not written after one; state writes are atomic; a single-instance lock is taken; an auth error (status 401) writes an error marker and exits non-zero. Then review the example adapter and config as the only per-source surface.
- `templates/lock-holder.sh` and `templates/rotate-queue.sh` are new in 1.1.0 and have no production ancestor beyond the inline lock one-liner they replace; `tests/hook/run.sh` is their evidence.
- `templates/worker-brief.md` vs the two production briefs. It is a synthesis, not a copy — confirm the structure (loop / alive file / worker stop file / exit report) is verbatim and the per-task rules are placeholders, not invented rules. Confirm the "Reporting (resolve)" section is present with `{{RESOLVE_MODE}}` and the four verdicts, and that the brief addresses the side chat agent (its exit report is its final message in its chat). Confirm the brief's `{{STOP_FILE}}` value differs from the daemon's stop file (registry `stop_file` / config `stop_file_name`) — a shared path is the Nov 14 footgun (ADR-17).
- `templates/daemon-watchdog.sh` and `templates/daemon-registry.example.json` vs the production watchdog. The script should read the registry (no hard-coded daemon list), check the daemon stop file before waking, use anchored `pgrep` (rejecting an unanchored pattern as a config error), read `polled_at` (never the file's mtime) for the heartbeat, and wake only once per cooldown per daemon. Confirm the registry example's `stale_secs` values follow poll interval + first backoff step + call timeout, and that the worker brief re-checks the daemon stop file and `pgrep` before starting and carries a "Reporting (resolve)" section with `{{RESOLVE_MODE}}` and the four verdicts.
- `templates/router-brief.md` and `templates/slice-worker-brief.md` vs the Varisia orchestrator skill. These are the only Shape B evidence — confirm the routing-table and slice-ownership placeholders are genuinely per-project, not Varisia-specific rules smuggled in as generic.

### 2. The rules — are they load-bearing or decorative?

For each operating rule in the skill, ask: what failure would happen without it? The design doc gives the failure for each. If a rule has no failure behind it, flag it. In particular:

- **Matched-poll (fastest producer).** Confirm the reasoning holds for a queue with exactly one producer (match the daemon) and for a queue with multiple producers (match the fastest). Varisia's 5s/10s case is the test: the workers' 5s is justified only because sibling handoffs arrive at any moment. If a future instance has workers polling faster than *every* producer, that is a violation, not a refinement.
- **seen_absent.** Confirm the hook template records `seen_absent` on the no-file branch *and* that the baseline branch requires the file to have pre-existed the hook's first observation. A hook that baselines on first sight of a fresh file reintroduces the first-canary bug.
- **Daemon baseline.** Confirm the template stays unbaselined on an empty first poll (B1). This is the one defect that was a live production bug.
- **Hook prompt.** Confirm the template carries all six requirements (poll interval + exit rule, handoff verification — the handoff must reach main and name the poller's side chat, "do not act yourself" and do not spawn a subagent yourself, payload carries only the newest item's identifiers and the count — never message text — the untrusted-data rule, and the RESOLVE instruction: the side chat agent's brief carries one, and main resolves the verdict line). A shortened prompt reintroduces silent data loss on a failed handoff or a prompt-injection path through the wake payload.
- **Liveness check.** Confirm it is required, not optional, in the worker-brief template — and confirm it reads `polled_at` (the heartbeat), not the file's mtime, and checks for an `error.json` marker.

### 3. The numbers — are the latencies honest?

- Second canary: post → reply 4m 35s, wake → reply 3m 42s, daemon 18s, hook 35s. These were recomputed from transcript timestamps by the adversarial reviewer and confirmed.
- First canary: wake → reply 3m 7s; end-to-end 14m 32s only because the baseline bug held it ~11 min. Do not quote 14m 32s as the cold start.
- Discord warm reply: ~23s end-to-end. The Discord cold start is *unmeasured* — do not quote a cold-start number for Discord.
- The skill's "post → wake ≤120s" bound (daemon ≤60s + hook ≤60s) is a bound, not a measurement. The measured post → wake was 53s (second canary: daemon 18s + hook 35s).

### 4. The placeholders and the adapter — can a fresh agent fill them?

The daemons have no placeholders. For the hook and the briefs, pick one template and fill every `{{...}}` placeholder for a hypothetical poller (the cross-template ones are listed in `local-subagent-poller/SKILL.md`). Check:

- Every placeholder is defined in the template's header comment or the SKILL's placeholder table.
- No placeholder is ambiguous: `{{TASK_JQ}}` is a jq filter returning identifiers only, `{{ROUTING_TABLE}}` is a complete event-type to queue map.
- No placeholder is decorative: `{{HOOK_NAME}}` was removed for exactly this reason.

Then write a source adapter and config from `example_http_adapter.py` (or the TS one) for a hypothetical source, using only the SKILL's interface and config tables, and run the daemon with `--config`.

### 5. The usage skill — does it cover operating, not scaffolding?

`local-subagent-poller-usage/SKILL.md` is the operator's skill. Confirm it does not duplicate the SDK skill's scaffolding workflow, and that its three health checks (daemon, cursor, lock and alive file) are sufficient to diagnose the failure modes in the SDK skill. If a failure mode in the SDK skill has no corresponding check or fix in the usage skill, flag it.

## Known gaps (already acknowledged — decide whether each is acceptable)

1. **Shape B is proven by one instance.** The orchestrator shape is extracted from Varisia live play alone. The skill marks it proven-by-one. A second orchestrator-style build is what would confirm the generalization. Acceptable for now, but do not present Shape B as battle-tested.
2. **Scribe polls at 15s, slower than its producers.** The Varisia scribe can lag a dispatch by up to 15s. The instances file notes it. It is a latency cost, not a correctness bug — but a new orchestrator should not copy the 15s rate without that cost in mind.
3. **Per-channel failures are now counted (fixed in 1.0.1).** Per-channel errors used to be swallowed inside `pollOnce`, so the outer backoff only fired on whole-cycle failures. The TS template now counts them: an all-channels-failed cycle is a cycle failure, the heartbeat is not written after one, and the daemon exits after N in a row. One bad channel still must not stall the others — that part is unchanged.
4. **Template-only fixes.** Fixes recorded in the CHANGELOG as template-only (1.0.1 and 1.0.2, and the 1.1.0 breaking changes) do not reach pollers built from earlier versions until the same changes are applied there.
5. **The stop-file + hook interaction.** The hook does not check either stop file, so a wake after the worker stop file is touched hands off and main wakes an agent that exits immediately (one wasted cold start). Documented, not fixed — faithful to production. Decide whether a future version should have the hook check the worker stop file.
6. **The Discord cold start is unmeasured.** Do not quote a Discord cold-start number until the owner's two test mentions run. The Discord side chat itself is also still pending creation (Nov 14) — the migration is file-level only until main creates it.
7. **The Varisia confirmed chain is configured, not yet live.** The Shape A daemon (`varisia-table-wake` hook disabled, daemon stopped) and the side chat agent as orchestrator are confirmed by Jaeson (Nov 14) but unproven; the old script-router orchestrator stays running until the new chain is proven. Do not present the Varisia side-chat-agent chain as live.

## Open questions for the reviewer

- Should the SDK gain a second Shape B instance before it is presented as general, or is the proven-by-one marking sufficient?
- Should the hook check the worker stop file (closing gap 5), or is the wasted cold start acceptable?
- Is the 10-minute idle exit the right default for Shape A workers, or should it be a placeholder the scaffolder sets?
- The worker-brief template is a synthesis of two production briefs, not either one — is the synthesis faithful enough, or should the SDK ship both production briefs as examples?
