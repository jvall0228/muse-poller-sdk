# Review guide

For anyone reviewing this SDK before adopting it. What to check, in order of importance, and what is already known to be imperfect.

## How to review it

1. **Read the skill first** (`local-subagent-poller/SKILL.md`, ~150 lines). It is the contract: the two shapes, the pieces, the workflow, the operating rules, the measured latencies, the output contract.
2. **Read the design doc** (`docs/design.md`) for why each rule exists and what failure motivated it.
3. **Read the verification doc** (`docs/verification.md`) for what was found by adversarial review and how each fix was verified.
4. **Spot-check one template against its production ancestor** (see "Template fidelity" below). Do not trust the skill's claim that every line traces — verify one.
5. **Check the open questions** at the end of this guide and decide whether each is acceptable, needs a fix, or needs a second implementation before adoption.

## What to check

### 1. Template fidelity — does each template trace to production?

Every template line must trace to one of the instances in `local-subagent-poller/references/instances.md`. Spot-check:

- `templates/hook-watch.sh` vs the production wake scripts (chat mentions, team chat queue). The logic body should be identical apart from placeholders. The seen_absent branch, the worker-lock check, and the cursor-based outstanding rule are the load-bearing parts — confirm all three are present and in the right order.
- `templates/daemon.py` vs a production team-queue watcher. Confirm the baseline branch only marks baselined when messages were seen, the backoff indexes `consecutive_failures - 1`, state writes are atomic (temp + fsync + rename), the daemon takes a single-instance lock, and an auth error writes an error marker and exits non-zero.
- `templates/daemon.ts` vs a production chat-mentions watcher. Confirm the per-channel cursor advances per message after its append succeeds, the first-sight baseline, and that per-channel failures are counted — an all-channels-failed cycle is a cycle failure and the heartbeat is not written after one.
- `templates/worker-brief.md` vs the two production briefs. It is a synthesis, not a copy — confirm the structure (loop / alive file / stop file / exit report) is verbatim and the per-task rules are placeholders, not invented rules.
- `templates/router-brief.md` and `templates/slice-worker-brief.md` vs the live-game orchestrator skill. These are the only Shape B evidence — confirm the routing-table and slice-ownership placeholders are genuinely per-project, not game-specific rules smuggled in as generic.

### 2. The rules — are they load-bearing or decorative?

For each operating rule in the skill, ask: what failure would happen without it? The design doc gives the failure for each. If a rule has no failure behind it, flag it. In particular:

- **Matched-poll (fastest producer).** Confirm the reasoning holds for a queue with exactly one producer (match the daemon) and for a queue with multiple producers (match the fastest). The live game session's 5s/10s case is the test: the workers' 5s is justified only because sibling handoffs arrive at any moment. If a future instance has workers polling faster than *every* producer, that is a violation, not a refinement.
- **seen_absent.** Confirm the hook template records `seen_absent` on the no-file branch *and* that the baseline branch requires the file to have pre-existed the hook's first observation. A hook that baselines on first sight of a fresh file reintroduces the first-canary bug.
- **Daemon baseline.** Confirm the template stays unbaselined on an empty first poll (B1). This is the one defect that was a live production bug.
- **Hook prompt.** Confirm the template carries all five requirements (poll interval + exit rule, spawn verification with one retry, "do not act yourself", payload carries only the newest item's identifiers and the count — never message text — and the untrusted-data rule). A shortened prompt reintroduces silent data loss on a failed spawn or a prompt-injection path through the wake payload.
- **Liveness check.** Confirm it is required, not optional, in the worker-brief template — and confirm it reads `polled_at` (the heartbeat), not the file's mtime, and checks for an `error.json` marker. A production team-queue brief now has one (it was added Nov 13 and is unexercised).

### 3. The numbers — are the latencies honest?

- Second canary: post → reply 4m 35s, wake → reply 3m 42s, daemon 18s, hook 35s. These were recomputed from transcript timestamps by the adversarial reviewer and confirmed.
- First canary: wake → reply 3m 7s; end-to-end 14m 32s only because the baseline bug held it ~11 min. Do not quote 14m 32s as the cold start.
- Discord warm reply: ~23s end-to-end. The Discord cold start is *unmeasured* — do not quote a cold-start number for Discord.
- The skill's "post → wake ≤120s" bound (daemon ≤60s + hook ≤60s) is a bound, not a measurement. The measured post → wake was 53s (second canary: daemon 18s + hook 35s).

### 4. The placeholders — can a fresh agent fill them?

Pick one template and fill every `{{...}}` placeholder for a hypothetical poller. Check:

- Every placeholder is defined (in the template's header comment or the skill). The worker-brief template's definitions sit at the top; the daemon templates' in their docstrings.
- No placeholder is ambiguous: `{{POLL_SECS}}` must be a bare integer, `{{TASK_JQ}}` is a jq filter, `{{ROUTING_TABLE}}` is a complete event-type → queue map.
- No placeholder is decorative: `{{HOOK_NAME}}` was removed for exactly this reason (documented but never instantiated).

### 5. The usage skill — does it cover operating, not scaffolding?

`local-subagent-poller-usage/SKILL.md` is the operator's skill. Confirm it does not duplicate the SDK skill's scaffolding workflow, and that its four health checks (daemon, cursor, lock, alive file) are sufficient to diagnose the failure modes in the SDK skill. If a failure mode in the SDK skill has no corresponding check or fix in the usage skill, flag it.

## Known gaps (already acknowledged — decide whether each is acceptable)

1. **Shape B is proven by one instance.** The orchestrator shape is extracted from a live game session alone. The skill marks it proven-by-one. A second orchestrator-style build is what would confirm the generalization. Acceptable for now, but do not present Shape B as battle-tested.
2. **Scribe polls at 15s, slower than its producers.** The live game session's scribe can lag a dispatch by up to 15s. The instances file notes it. It is a latency cost, not a correctness bug — but a new orchestrator should not copy the 15s rate without that cost in mind.
3. **Per-channel failures are now counted (fixed in 1.0.1).** Per-channel errors used to be swallowed inside `pollOnce`, so the outer backoff only fired on whole-cycle failures. The TS template now counts them: an all-channels-failed cycle is a cycle failure, the heartbeat is not written after one, and the daemon exits after N in a row. One bad channel still must not stall the others — that part is unchanged.
4. **The team-queue brief's liveness check is unexercised.** Added Nov 13 (M7). It only takes effect on the next worker spawn.
5. **The production team-queue watcher fix applies on next restart.** The B1 + N3 fixes are in the file but the running daemon loaded the old code. Low urgency (the daemon is past its first poll), but confirm the restart happens and the daemon comes back healthy. The 1.0.1 template fixes (lock, heartbeat, atomic writes, auth exit) are template-only until the production watchers are updated too.
6. **The stop-file + hook interaction.** The hook does not check the stop file, so a wake after the stop file is touched spawns a worker that exits immediately (one wasted cold start). Documented, not fixed — faithful to production. Decide whether a future version should have the hook check the stop file.
7. **The Discord cold start is unmeasured.** Do not quote a Discord cold-start number until the owner's two test mentions run.

## Open questions for the reviewer

- Should the SDK gain a second Shape B instance before it is presented as general, or is the proven-by-one marking sufficient?
- Should the hook check the stop file (closing gap 6), or is the wasted cold start acceptable?
- Is the 10-minute idle exit the right default for Shape A workers, or should it be a placeholder the scaffolder sets?
- The worker-brief template is a synthesis of two production briefs, not either one — is the synthesis faithful enough, or should the SDK ship both production briefs as examples?
