# Using a Subagent Poller — local copy

Operate a poller built with the Subagent Poller SDK: start it, check its health, stop and resume it, and fix it when it stalls.

## Installation

No package manager, registry, or install command — installation is copying the directory.

- The copy that runs lives at `~/workspace/skills/local-subagent-poller-usage/` — the compiled wisp binary discovers skills from `~/workspace/skills/` only.
- Mirror it to `~/workspace/custom-skills/local-subagent-poller-usage/` and keep the two copies byte-identical (`diff -rq` after any edit).
- Each copy must contain `SKILL.md` (native format, no frontmatter) + `skill.yaml`. No `wisp.yaml` — this is a prompt-only skill with no CLI entrypoint, so there is no `wisp local-subagent-poller-usage` command.
- This repo is the upstream copy. The harness loads the local `~/workspace/skills/` copy, not this one — after changing anything here, copy the directory to `~/workspace/skills/local-subagent-poller-usage/` and mirror it to `~/workspace/custom-skills/local-subagent-poller-usage/` (keep the two copies byte-identical) so the change takes effect.
