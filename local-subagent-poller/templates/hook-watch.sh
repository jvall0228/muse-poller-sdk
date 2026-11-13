#!/usr/bin/env bash
# hook-watch.sh — TEMPLATE for a two-tier poller wake hook.
# Extracted from the production hooks (Discord mentions + Slack fleet-queue,
# Nov 13 2026). Copy this file into the new poller's hooks directory and fill
# in the {{...}} placeholders. Keep the structure verbatim — the seen_absent
# rule and the no-advance-while-alive rule are load-bearing.
#
# Placeholders:
#   {{QUEUE}}         — absolute path to the queue JSONL file (daemon appends)
#   {{ALIVE}}         — absolute path to the worker alive file
#   {{ITEM_NOUN}}     — plural noun for the items, e.g. "queue items" / "mentions"
#   {{PAYLOAD_KEY}}   — payload key for the count, e.g. "new_items" / "new_mentions"
#   {{NO_FILE_REASON}} — silent reason when the queue file is absent, e.g.
#                       "no queue file yet" / "no mentions queue yet"
#   {{WAKE_REASON}}   — wake reason, e.g. "new fleet-queue item(s), no worker alive"
#   {{TASK_JQ}}       — jq filter extracting the wake payload from the last
#                       queue line, e.g. '{ts, user, text}' or
#                       '{channel_name, author_username, content}'
#
# Register with: hooks.add, script path = this file, poll interval 60s,
# prompt = templates/hook-prompt.md (filled in — do not shorten it; the
# spawn-verification clause is load-bearing).
# Dry-run all three states before enabling (see SKILL.md, "Dry-run note":
# state 2 needs the state file seeded with {"seen_absent": true} first,
# or test it live with hooks.run):
#   1. no queue file        -> silent "no queue file yet"
#   2. file appears (new)   -> WAKE (never baseline a fresh file)
#   3. no new lines         -> silent "no new <items>"
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

QUEUE="{{QUEUE}}"
ALIVE="{{ALIVE}}"
ALIVE_FRESH_SECS=180

state=$(hook_state_get 2>/dev/null \
    | jq -c 'if type == "object" then . else {} end' 2>/dev/null) \
    || state='{}'
[ -n "$state" ] || state='{}'

printf -v now '%(%s)T' -1
dry_run=0; [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ] && dry_run=1

set_state() { if [ "$dry_run" -eq 0 ]; then hook_state_set "$1"; fi; }

if [ ! -f "$QUEUE" ]; then
    # Record that we looked and the file was absent: if it appears later,
    # its lines are NEW work, not history — they must wake, not baseline.
    state=$(printf '%s' "$state" | jq -c '.seen_absent = true')
    set_state "$state"
    silent "{{NO_FILE_REASON}}" '{}'
fi

lines=$(wc -l < "$QUEUE" | tr -d ' ')
has_watermark=$(printf '%s' "$state" | jq -r 'has("watermark")')
seen_absent=$(printf '%s' "$state" | jq -r '.seen_absent // false')
if [ "$has_watermark" != "true" ] && [ "$seen_absent" != "true" ]; then
    # Fresh hook and the file pre-existed us: baseline to current lines and
    # stay silent, so history never wakes anyone. But if we previously saw
    # the file absent (seen_absent), these lines arrived after we started
    # watching — they are new work, so fall through and wake on them.
    state=$(printf '%s' "$state" | jq -c --argjson w "$lines" '.watermark = $w')
    set_state "$state"
    silent "baseline at $lines lines" '{}'
fi
watermark=$(printf '%s' "$state" | jq -r '.watermark // 0')

if [ "$lines" -le "$watermark" ]; then
    silent "no new {{ITEM_NOUN}} ($lines lines, watermark $watermark)" '{}'
fi

# New item(s). Is an active worker already on them? A fresh alive-file
# means yes — stay silent WITHOUT advancing the watermark, so that if the
# worker dies before consuming them, the next poll still wakes a replacement.
if [ -f "$ALIVE" ]; then
    alive_mtime=$(stat -c %Y "$ALIVE" 2>/dev/null || echo 0)
    age=$((now - alive_mtime))
    if [ "$age" -lt "$ALIVE_FRESH_SECS" ]; then
        silent "worker alive (alive file ${age}s old); $((lines - watermark)) new {{ITEM_NOUN}} left to it" '{}'
    fi
fi

# No live worker: wake one, and advance the watermark so these lines never
# re-wake. (If the woken worker fails to spawn the subagent, the next new
# item re-wakes; the subagent itself drains the backlog from its cursor.)
new_count=$((lines - watermark))
state=$(printf '%s' "$state" | jq -c --argjson w "$lines" '.watermark = $w')
set_state "$state"
task=$(tail -n 1 "$QUEUE" | jq -c '{{TASK_JQ}}' 2>/dev/null || echo '{}')
wake "{{WAKE_REASON}}" "{\"{{PAYLOAD_KEY}}\": $new_count, \"latest\": $task}"
