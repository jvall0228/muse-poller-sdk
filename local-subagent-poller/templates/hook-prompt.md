# {{HOOK_PROMPT_TITLE}} — wake-time spawner instruction (template)

<!-- TEMPLATE for a two-tier poller hook prompt. Extracted from the
     production hook prompts (Discord mentions + Slack fleet-queue, Nov 13
     2026). Fill in the {{...}} placeholders and use the result verbatim as
     the hook's prompt in `hooks.add`. Do not shorten it: the four
     load-bearing requirements are (1) the worker's poll interval and exit
     rule, (2) spawn verification with one retry, (3) "do not act yourself",
     (4) the payload carries only the newest item. The spawn-verification
     clause matters most: the hook advances its watermark when it wakes, so
     a failed spawn is silent data loss — no re-wake until the *next* new
     item, and the queued item sits unhandled.

     Placeholders:
     {{ITEM_NOUN}}        — e.g. "fleet-queue item(s)" / "@Wisp mention(s)"
     {{SOURCE}}            — e.g. "in Slack" / "in <your Discord server> (Discord)"
     {{WORKER_NAME}}       — e.g. "queue worker" / "mention worker"
     {{BRIEF_PATH}}        — absolute path to the worker brief
     {{QUEUE_PATH}}        — absolute path to queue.jsonl
     {{POLL_INTERVAL}}     — e.g. "every 60 seconds" / "every 10 seconds"
     {{PER_ITEM_BEHAVIOR}} — what the worker does per item, e.g. "reads each
                             item's thread, and acts on items naming Muse
                             under the proactive grant (claim, work, done in
                             the thread)" / "replies as Wisp only when a
                             reply is warranted"
     {{ACT_VERB}}          — e.g. "act on the queue item" / "reply to the mention"
     {{SOURCE_NAME}}       — e.g. "Slack" / "Discord"
-->

New {{ITEM_NOUN}} arrived {{SOURCE}} and no {{WORKER_NAME}} is currently alive. Spawn the active {{WORKER_NAME}} subagent using the brief at {{BRIEF_PATH}} — it consumes {{QUEUE_PATH}} {{POLL_INTERVAL}}, {{PER_ITEM_BEHAVIOR}}, touching the alive file every iteration and exiting after 10 minutes quiet. Verify the subagent is running after spawning; if the spawn fails, retry once, and if it still fails, say so in your report. Do not {{ACT_VERB}} yourself and do not post in {{SOURCE_NAME}} yourself. The wake payload carries the newest item; the subagent reads the full queue itself.
