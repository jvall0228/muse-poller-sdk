# Decisions

Architecture Decision Records for the Subagent Poller SDK. Each entry: the decision, the context, the alternatives considered, and the consequences. Dated 2026-11-13 unless noted.

## ADR-1: Two shapes on one core, not one shape

**Decision.** The SDK carries two shapes — Shape A (two-tier poller) and Shape B (orchestrator) — sharing one core (queue protocol, alive file, stop file, rate-limit rules).

**Context.** The pattern started as always-warm workers for live game play (Varisia, Nov 12). The two-tier form was built the next day for intermittent work (Discord mentions, Slack fleet-queue). The two forms share the queue protocol and the worker loop but differ in wake-up, lifetime, and routing.

**Alternatives.** (a) One shape only (two-tier), with the orchestrator as a separate pattern — rejected, because the queue protocol, the alive file, the stop file, and the rate-limit rules are identical, and splitting them would duplicate the core. (b) One shape only (orchestrator), with the two-tier form as a degenerate case — rejected, because the hook wake and the idle exit are not degenerate; they are the whole point of the two-tier form.

**Consequences.** The skill is longer (two workflows), but the core is stated once. Shape B is marked proven-by-one; a second orchestrator instance is needed to confirm the generalization.

## ADR-2: A skill, not a library

**Decision.** The SDK is a prompt-only skill with templates — no code library, no CLI, no `wisp.yaml`.

**Context.** A poller is a set of behaviors an agent performs, not a program you install. The agent is the runtime.

**Alternatives.** (a) A library with a host process — rejected: it would need a config format, a supervisor, and an operator, for behavior the agent already performs. (b) A CLI (`wisp poller ...`) — rejected: there is no CLI entrypoint to declare, and the templates are the deliverable. The skill-extensions rule confirms: `wisp.yaml` only when a runnable command exists.

**Consequences.** The SDK is only usable by an agent that can read the skill and fill the templates. It cannot be installed or run standalone. That is acceptable: the target user is an agent scaffolding a poller, not a human installing a tool.

## ADR-3: The worker poll matches the fastest producer

**Decision.** The worker's poll interval matches the fastest producer of its queue — the daemon for a single-producer queue, the fastest producer (router or sibling worker) for a multi-producer queue.

**Context.** The original rule (Nov 13, owner's words: "Worker poll and daemon poll should always match otherwise it's just wasting cycles") was stated for single-producer queues. The Varisia orchestrator appeared to violate it (workers 5s, router 10s). The refinement came from asking *what produces work in the queue*: the router dispatches at most every 10s, but sibling workers hand off at any moment, so 5s is the right rate for the sibling-handoff producer.

**Alternatives.** (a) Keep the rule as "match the daemon" — rejected, because it would make the Varisia workers poll at 10s and add up to 5s of latency to every sibling handoff (including the narration → voice pipeline). (b) Drop the rule — rejected, because the fleet worker's original 5s poll against a 60s daemon was 12 checks per possible delivery, 11 of which could find nothing.

**Consequences.** The rule is now per-producer, which is harder to state but correct. The scribe at 15s is the known violation in the other direction (slower than its producers, lags up to 15s) — documented, not fixed.

## ADR-4: The hook prompt is a template, not a one-liner

**Decision.** The wake-time spawner instruction is a full template (`templates/hook-prompt.md`), not a one-line summary.

**Context.** The skill originally suggested "spawn the active worker subagent using the brief at <path>." The production prompts carry four load-bearing requirements. The adversarial review (B3) showed the one-liner drops the most important one: spawn verification.

**Alternatives.** (a) Keep the one-liner and rely on the worker brief — rejected: the brief is read by the worker, not by the wake-time spawner; the hook prompt is the only instruction the spawner gets. (b) Put the requirements in the skill and reference them — rejected: the prompt must be usable verbatim at registration time, not reconstructed from the skill.

**Consequences.** The skill has one more template to maintain, and the prompt is longer. The gain is that a failed spawn is no longer silent data loss.

## ADR-5: Dry-run state 2 is tested by seeding, not by pretending

**Decision.** The skill documents the state-seeding maneuver (write `{"seen_absent": true}` into the hook's state file before dry-running) and the live-run alternative, instead of claiming dry-run covers all three states.

**Context.** A hook dry-run does not persist state, so the "file appears → WAKE" state is unreachable by dry-run alone on a fresh hook (B2). The skill originally prescribed dry-running all three states, which would have led a fresh agent to accept the baseline as correct behavior — the FLEET-0003 bug.

**Alternatives.** (a) Change the hook runtime so dry-runs persist state — not ours to change. (b) Drop the three-state dry-run and prescribe live testing only — rejected, because dry-running states 1 and 3 is still useful and safe.

**Consequences.** The skill is honest about what a dry-run can and cannot prove. The seeding step is a manual maneuver that must be documented exactly (the file path and the JSON), which the skill does.

## ADR-6: Daemon health is a required tripwire, not an option

**Decision.** Every worker brief must include a liveness check (daemon process alive + `last-seen.json` fresh), and the template makes it required.

**Context.** The skill presented the liveness check as universal while templating it as optional, and the production fleet brief had none (M7). A poller with no tripwire has a dead daemon go unnoticed until someone checks by hand.

**Alternatives.** (a) Keep it optional — rejected: an optional tripwire is no tripwire, and the fleet instance proved it (no check at all). (b) Have the hook check daemon health — rejected: the hook's job is to watch the queue, not the daemon; the worker is the one that reads the queue and can check.

**Consequences.** The worker brief template is longer. The production fleet brief gained a liveness check (Nov 13, unexercised until the next spawn).

## ADR-7: The public copy is sanitized, not identical

**Decision.** The public repo's copy of the skill sanitizes private identifiers (Discord guild/channel/bot IDs, Slack team/channel/bot IDs, the private server name, the owner's name) to placeholders. The local copies keep the real values.

**Context.** The SDK's value is the templates and the rules, not the instance IDs. The IDs identify the owner's private servers and channels; publishing them adds nothing for a reader and leaks identifiers that need not be public.

**Alternatives.** (a) Publish the local copy verbatim — rejected: the IDs are unnecessary and the server name identifies a private two-person server. (b) Strip the instances file entirely — rejected: the instances are the evidence the templates trace to; a skill without evidence is an assertion.

**Consequences.** The public and local copies diverge on identifiers. The divergence is documented here and is limited to the sanitized values (verified by grep: no identifiers remain in the public copy). If the templates change, both copies must be updated — the local sync convention (two local copies kept identical) extends to the public copy's structure, not its identifiers.
