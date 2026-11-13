# Changelog

## 1.0.0 — 2026-11-13

The first public release. Extracted from three live implementations (Varisia live play, Discord mentions, Slack fleet-queue).

### Added

- **The SDK skill** (`local-subagent-poller/`): two shapes on one core — Shape A two-tier poller and Shape B orchestrator — with the pieces, the workflow, the operating rules, the measured latencies, and the output contract.
- **Seven templates**: `daemon.py`, `daemon.ts`, `hook-watch.sh`, `hook-prompt.md`, `worker-brief.md`, `router-brief.md`, `slice-worker-brief.md`.
- **The operator's skill** (`local-subagent-poller-usage/`): start, health-check, stop/resume, troubleshoot a built poller.
- **Documentation for review** (`docs/`): `design.md` (why each rule exists), `verification.md` (adversarial review + fixes + live tests), `review-guide.md` (what to check, known gaps, open questions), `decisions.md` (ADRs).
- **Instances inventory** (`local-subagent-poller/references/instances.md`): the three live implementations and the rate-limit numbers per source.

### Fixed (adversarial review, same day)

- **B1 — Empty-first-poll baseline bug.** The daemon template (and the production fleet watcher) marked itself baselined even when the first poll returned zero messages, which would have queued the whole recent history as new work. Now it stays unbaselined until its first poll actually sees messages.
- **B2 — Untestable dry-run state.** The skill prescribed dry-running the "file appears → WAKE" hook state, which is unreachable by dry-run alone on a fresh hook. The skill now documents the state-seeding maneuver and the live-run alternative.
- **B3 — Missing hook-prompt template.** Added `templates/hook-prompt.md`, templating the wake-time spawner instruction verbatim from production (including spawn verification).
- **M1–M8 + N1–N8.** Matched-poll reframed as "fastest producer"; FLEET-0002 lesson added; `is_new` made a TODO stub; `queue_item` defaults to the fuller shape; Discord daemon template added; canary ordering guarded; daemon-health liveness check made required; daemon start commands added; hook template fully parameterized; timeout rule corrected; backoff off-by-one fixed (template + production watcher); wake-latency bound corrected; overclaim softened; placeholder ergonomics fixed; stop-file + hook interaction documented; Discord backoff reachability documented; dead imports removed.

### Measured

- Shape A cold start (fleet-queue, clean run): post → reply 4m 35s; wake → reply 3m 42s.
- Shape A warm reply (Discord): ~23s end-to-end.
- Shape B (Varisia session 2): 6 tasks routed, no errors.
- Scratch live test of the templates: canary → hook wake (live) → worker consumed → cursor advanced → no double-wake.

### Known gaps

- Shape B is proven by one instance (Varisia). A second orchestrator-style build is what would confirm the generalization.
- The Discord cold start is unmeasured (owner's two test mentions pending).
- The production fleet watcher's B1 + N3 fixes apply on its next restart.
- The fleet brief's liveness check is unexercised until the next worker spawn.
