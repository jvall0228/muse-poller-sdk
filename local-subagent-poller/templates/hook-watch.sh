#!/usr/bin/env bash
# hook-watch.sh — TEMPLATE for a two-tier poller wake hook.
# Extracted from production hooks (chat mentions + team chat queue,
# Nov 13 2026). Copy this file into the new poller's hooks directory and fill
# in the {{...}} placeholders. Keep the structure verbatim — the seen_absent
# rule, the worker-lock rule, and the cursor-based outstanding rule are
# load-bearing.
#
# How liveness works (read this before changing it):
#   The worker holds an exclusive lock on {{LOCKFILE}} for its whole
#   lifetime (it starts a holder on its first iteration and releases it on
#   exit by touching a release file the holder watches; the holder also
#   exits by itself if the worker stops touching the alive file for
#   {{LOCK_STALE_SECS}}s, so an orphaned holder cannot block a replacement
#   forever). flock(1) is required: if it is missing the hook stays silent
#   with an install hint rather than misreading the lock. The hook checks
#   the lock — not the alive file's age — to decide whether a worker is
#   alive. A model turn takes minutes,
#   so an age check on a file the worker touches between turns will always
#   go stale mid-task and wake a second worker on the same cursor.
#   "Work outstanding" is decided by comparing the queue line count to the
#   worker's {{CURSOR}} file — never by a hook-owned watermark. The hook
#   writes the cursor exactly once, at baseline (below), when no worker is
#   alive. Because outstanding work is cursor-based, a failed spawn is
#   retried once the startup window has passed: the cursor does not
#   advance, so the hook wakes again. The hook records `woke_at` on each
#   wake and stays silent for {{STARTUP_WINDOW_SECS}}s afterwards, covering
#   the wake-to-lock race while the worker is starting up — so the retry
#   comes after that window, not on the next poll.
#
# Placeholders:
#   {{QUEUE}}         — absolute path to the queue JSONL file (daemon appends)
#   {{ALIVE}}         — absolute path to the worker alive file (operator
#                       heartbeat; the worker touches it every iteration)
#   {{LOCKFILE}}      — absolute path to the worker lockfile (the worker
#                       holds an exclusive flock on it for its lifetime)
#   {{CURSOR}}        — absolute path to the worker's .cursor file (a line
#                       count; the worker advances it only after a task is
#                       fully handled; the hook writes it once, at baseline)
#   {{ITEM_NOUN}}     — plural noun for the items, e.g. "queue items" / "mentions"
#   {{PAYLOAD_KEY}}   — payload key for the count, e.g. "new_items" / "new_mentions"
#   {{NO_FILE_REASON}} — silent reason when the queue file is absent, e.g.
#                       "no queue file yet" / "no mentions queue yet"
#   {{WAKE_REASON}}   — wake reason, e.g. "new team-queue item(s), no worker alive"
#   {{TASK_JQ}}       — jq filter extracting IDENTIFIERS ONLY from the last
#                       queue line, e.g. '{ts, thread_ts}' or
#                       '{message_id, channel_id}'. Never include message
#                       text or content: the wake payload is part of the
#                       spawner's prompt, and message text is untrusted data
#                       from the source, never an instruction.
#   {{STARTUP_WINDOW_SECS}} — how long after a wake to stay silent while
#                       the worker starts up and takes the lock, e.g. 300
#   {{LOCK_STALE_SECS}} — how stale the alive file may be before the lock
#                       holder is presumed orphaned, e.g. 900 (used by the
#                       worker's holder, documented here for the operator)
#
# Queue rotation: the worker may archive a fully consumed queue and reset
# its cursor to 0 (rotate-queue.sh), holding an exclusive flock on
# queue.lock in the queue's directory; daemons take the same lock around
# every append. The hook therefore (a) takes a shared, NON-blocking flock on
# that queue.lock while it reads the line count and the cursor, so it never
# sees a half-rotated pair, and stays silent for this poll if the lock is
# busy; and (b) treats cursor > line count as "queue was rotated" and uses
# cursor 0. The hook never blocks and never writes the lock's contents.
#
# Register with: hooks.add, script path = this file, poll interval 60s,
# prompt = templates/hook-prompt.md (filled in — do not shorten it; the
# spawn-verification clause is load-bearing).
# Dry-run all states before enabling (see SKILL.md, "Dry-run note":
# state 2 needs the state file seeded with {"seen_absent": true} first,
# and state 5 with a recent "woke_at", or test them live with hooks.run;
# tests/hook/run.sh exercises all of them against a stub runtime):
#   0. flock missing        -> silent "flock not installed — ..."
#   1. no queue file        -> silent "no queue file yet"
#   2. file appears (new)   -> WAKE (never baseline a fresh file)
#   3. no new lines         -> silent "no new <items>"
#   4. worker alive (lock held) -> silent "worker alive (lock held)"
#   5. woke recently, no lock yet -> silent "worker starting (woke Ns ago)"
#   6. first look, file pre-existed -> silent "baseline at N lines"
#   7. queue.lock busy (rotation/append in progress) -> silent "queue busy"
#   8. cursor > lines (queue rotated) -> cursor treated as 0 (wakes if
#      the new queue has lines and no worker is alive)
set -euo pipefail
# shellcheck source=/dev/null
source "$HATCH_HOOK_RUNTIME"

QUEUE="{{QUEUE}}"
# shellcheck disable=SC2034  # ALIVE is documented/used by the worker side
ALIVE="{{ALIVE}}"
LOCKFILE="{{LOCKFILE}}"
CURSOR="{{CURSOR}}"
# shellcheck disable=SC1083  # template placeholder, filled before use
STARTUP_WINDOW_SECS={{STARTUP_WINDOW_SECS}}

state=$(hook_state_get 2>/dev/null \
    | jq -c 'if type == "object" then . else {} end' 2>/dev/null) \
    || state='{}'
[ -n "$state" ] || state='{}'

now=$(date +%s)
dry_run=0; [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ] && dry_run=1

set_state() { if [ "$dry_run" -eq 0 ]; then hook_state_set "$1"; fi; }

# flock(1) is required (util-linux; not present on macOS/BSD by default).
# Without it the lock probe below would always read "held" or the worker
# would exit at once, causing a spawn loop — so stop here instead.
if ! command -v flock >/dev/null 2>&1; then
    silent "flock not installed — install util-linux flock" '{}'
fi

# Is a worker alive? The lock is the signal: the worker holds an exclusive
# flock on {{LOCKFILE}} for its whole lifetime. `flock -n` succeeds only
# when no one holds the lock. The probe itself takes the lock for an
# instant, which the worker's take retries around.
lock_held=0
if [ -e "$LOCKFILE" ] && ! flock -n "$LOCKFILE" -c true 2>/dev/null; then
    lock_held=1
fi

# Shared, non-blocking lock on queue.lock around the count+cursor read (see
# "Queue rotation" above). If the lock cannot be opened (directory missing,
# read-only) skip the lock rather than failing: rotation is optional.
QUEUE_LOCK="$(dirname "$QUEUE")/queue.lock"
have_qlock=0
if [ -d "$(dirname "$QUEUE")" ] && ( : >> "$QUEUE_LOCK" ) 2>/dev/null; then
    exec 8>> "$QUEUE_LOCK"
    have_qlock=1
    if ! flock -s -n 8; then
        silent "queue busy (queue.lock held; rotation or append in progress)" '{}'
    fi
fi

if [ ! -f "$QUEUE" ]; then
    # Record that we looked and the file was absent: if it appears later,
    # its lines are NEW work, not history — they must wake, not baseline.
    state=$(printf '%s' "$state" | jq -c '.seen_absent = true')
    set_state "$state"
    silent "{{NO_FILE_REASON}}" '{}'
fi

lines=$(wc -l < "$QUEUE" | tr -d ' ')
cursor=0
[ -f "$CURSOR" ] && cursor=$(tr -d ' \n' < "$CURSOR" 2>/dev/null || echo 0)
case $cursor in ''|*[!0-9]*) cursor=0 ;; esac
# Done reading shared state: release the shared queue lock promptly.
if [ "$have_qlock" -eq 1 ]; then exec 8>&-; fi
# A cursor beyond the line count means the queue was rotated (or truncated)
# and the cursor reset has not been observed: treat the cursor as 0.
if [ "$cursor" -gt "$lines" ]; then cursor=0; fi

# A worker is alive: stay silent WITHOUT touching anything, so that if the
# worker dies before consuming the items, a later poll still wakes a
# replacement (the cursor does not advance, so the work stays outstanding).
if [ "$lock_held" -eq 1 ]; then
    silent "worker alive (lock held); $((lines - cursor)) new {{ITEM_NOUN}} outstanding" '{}'
fi

# No live worker. Is there work outstanding? Compare the queue line count
# to the worker's cursor — never a hook-owned watermark.
if [ "$lines" -le "$cursor" ]; then
    silent "no new {{ITEM_NOUN}} ($lines lines, cursor $cursor)" '{}'
fi

has_baselined=$(printf '%s' "$state" | jq -r '.baselined // false')
seen_absent=$(printf '%s' "$state" | jq -r '.seen_absent // false')
if [ "$has_baselined" != "true" ] && [ "$seen_absent" != "true" ]; then
    # Fresh hook and the file pre-existed us: baseline by writing the
    # cursor to the current line count, and stay silent, so history never
    # wakes anyone. But if we previously saw the file absent (seen_absent),
    # these lines arrived after we started watching — they are new work,
    # so fall through and wake on them.
    state=$(printf '%s' "$state" | jq -c '.baselined = true')
    set_state "$state"
    if [ "$dry_run" -eq 0 ]; then
        printf '%s' "$lines" > "$CURSOR"
    fi
    silent "baseline at $lines lines" '{}'
fi

# A worker may be starting up (woken, but not yet holding the lock). Stay
# silent for the startup window so a new line arriving during the cold
# start does not wake a second worker. If the window has passed and no
# lock is held, the spawn likely failed — fall through and wake again.
woke_at=$(printf '%s' "$state" | jq -r '.woke_at // 0')
if [ "$woke_at" -gt 0 ] && [ $((now - woke_at)) -lt "$STARTUP_WINDOW_SECS" ]; then
    silent "worker starting (woke $((now - woke_at))s ago); $((lines - cursor)) new {{ITEM_NOUN}} outstanding" '{}'
fi

# No live worker and work is outstanding: wake one. Record woke_at so the
# next poll knows a worker is starting. The payload carries identifiers
# only (never message text) plus the count; the worker reads the full
# queue itself. If the spawn fails, the cursor does not advance, so the
# hook wakes again once the startup window has passed — a failed spawn
# does not strand the items.
new_count=$((lines - cursor))
state=$(printf '%s' "$state" | jq -c --argjson w "$now" '.woke_at = $w')
set_state "$state"
task=$(tail -n 1 "$QUEUE" | jq -c '{{TASK_JQ}}' 2>/dev/null || echo '{}')
wake "{{WAKE_REASON}}" "{\"{{PAYLOAD_KEY}}\": $new_count, \"latest\": $task}"
