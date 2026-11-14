#!/usr/bin/env bash
# daemon-watchdog.sh — TEMPLATE for a daemon-supervision hook.
# Extracted from the production watchdog (daemon-watchdog, Nov 13 2026),
# generalized: one hook supervises every daemon in the registry, instead
# of one hook per daemon. Copy this file into ~/hooks/scripts/, fill in the
# {{...}} placeholders, and register it with `hooks.add` (60s poll,
# prompt = templates/watchdog-worker-brief.md, delivery main).
#
# How it works: every 60s it reads the registry and checks each daemon —
# process alive (anchored pgrep) AND heartbeat fresh (polled_at in
# last-seen.json). A daemon with its stop file present is intentionally
# stopped and skipped. It wakes a worker ONLY when a daemon is down, and
# only if no wake for that daemon fired inside the cooldown window. The
# wake payload names the daemons this wake covers and why — identifiers
# only, never logs or message text. Zero tokens while idle; a worker only spawns when
# a daemon is actually down. This replaces a recovery cron: it is
# event-driven (wakes only on a real outage) and recovers in ~1-2 min
# instead of up to an hour.
#
# Register exactly one watchdog hook. Two hooks would share no cooldown
# state and could double-wake for the same down daemon; the worker brief's
# re-check (pgrep before starting) is the backstop, not the plan.
#
# Failure behavior (read before changing it):
#   - No registry file, unreadable registry, duplicate daemon ids, or an
#     empty registry: silent with an explicit reason. There is nothing to
#     supervise, so waking would spawn a worker with no work; the reason
#     is visible in the hook log.
#   - A live daemon with a stale (or missing) heartbeat whose `log_file`
#     (optional registry field) ends in a recent `poll_failed` line is alive
#     and backing off during a source outage, not hung: no wake, named in
#     the reason as backing off. "Recent" = newer than that line's
#     backoff_secs + stale_secs. A restart cannot fix an outage. A missing,
#     unreadable or silent log, or one ending in anything else, wakes.
#   - A pgrep pattern that is not a valid regex (pgrep exits 2): that
#     entry is skipped and named in the reason. A bad pattern is a config
#     error, not a down daemon — waking on it would loop every cooldown.
#   - A pgrep pattern not anchored at both ends (^...$): that entry is
#     skipped and named in the reason. An unanchored pattern matches the
#     exec tool's background-session wrapper and reports a dead daemon
#     as alive — silent false-healthy, the worst failure for a watchdog.
#   - A {{...}} placeholder left unfilled, or a WAKE_COOLDOWN_SECS that is
#     not a plain non-negative integer (e.g. "10m"): silent with an
#     explicit reason. Left alone, the cooldown comparison errors inside
#     `if`, is read as false, and no daemon is ever woken — a silent
#     false-quiet that looks like normal operation.
#   - A pgrep pattern with an unparenthesised top-level `|`, or ending in
#     an escaped `\$`: treated as unanchored (the `^`/`$` would bind only
#     one alternative). Wrap alternations in a group: ^(a|b)$.
#   - A polled_at that is present but unparsable (not ISO-8601 and not an
#     epoch integer), or a heartbeat file that is not valid JSON at all:
#     that entry is skipped and named in the reason; it is NOT counted
#     healthy. Also unparseable: an empty file, a non-object, a null/false/
#     array polled_at, epoch milliseconds, and a timestamp more than 60s in
#     the future. Only a small negative age (heartbeat written a second
#     after this poll read the clock) is clamped to 0.
#   - Every entry skipped as a config error: the reason says "no daemons
#     supervised — config errors: ..." rather than "all daemons healthy".
#   - A daemon that never recovers (it wrote error.json on a 401 or
#     max_failures and exits on every restart): after
#     MAX_CONSECUTIVE_WAKES wakes in a row (default 3, override with the
#     WATCHDOG_MAX_CONSECUTIVE_WAKES env var) the hook goes silent for it
#     with an explicit "gave up" reason instead of spending an agent turn
#     every cooldown forever. The count lives in hook state (.wakes[id]);
#     it resets once the daemon has stayed healthy for a full cooldown since
#     its last wake (a flapping daemon that polls once and dies keeps its
#     count), or at once when it is intentionally stopped (create then
#     remove its stop file to re-arm after fixing it).
#   - A heartbeat file that exists but carries no polled_at (a daemon
#     predating the heartbeat rule): process-only check. The file's mtime
#     is NEVER a liveness signal — an idle daemon whose state file only
#     updates on new items would look dead (the failure the 1.0.1
#     heartbeat rule fixed). A heartbeat file that does not exist at all
#     while the process is alive means the daemon never completed a poll:
#     that one is down.
#   - A hook state that is malformed (non-object, or .waking/.wakes not an
#     object) is normalised, never fatal.
#   - If this script dies mid-run, nothing is lost: hook state is written
#     before a wake (`.waking[<id>] = now`, `.wakes[<id>] += 1`) and, when a
#     daemon has stayed healthy for a cooldown, to clear its wake count and
#     cooldown timestamp, so a death before
#     the wake leaves the next poll free to retry, and a death after it
#     only delays the next wake by the cooldown.
#
# Dependencies: bash, jq, pgrep (procps), GNU date (for -d on polled_at).
# All are checked at startup; a missing one ends the poll silently with
# the reason (the hook log shows it). See README Requirements.
#
# stale_secs per daemon is poll interval + first backoff step + call
# timeout (design.md, "Daemon heartbeat and error markers"): 60+60+60=180
# for a 60s daemon, 10+10+10=30 for a 10s one.
#
# The pgrep pattern is matched against the FULL command line (`ps -o
# args`), arguments included, and must be anchored at both ends: for the
# SDK daemon that is e.g. ^python3 .*/daemon\.py --config .*$ . A pattern
# that omits the arguments never matches, so the hook reports "process
# missing" and the worker's own pgrep re-check misses the running daemon.
#
# Placeholders:
#   {{REGISTRY_PATH}}      — path to daemon-registry.json, absolute or with
#                            a leading ~ (expanded), e.g.
#                            ~/hooks/state/daemon-registry.json
#   {{WAKE_COOLDOWN_SECS}} — how long after a wake for one daemon to stay
#                            silent while its worker restarts it, e.g. 600
#                            (digits only)
#
# Register with: hooks.add, script path = this file, poll interval 60s,
# prompt = templates/watchdog-worker-brief.md (filled in), delivery main.
# Dry-run states before enabling (seed the hook state file by hand where
# noted — dry-run does not persist state):
#   1. no registry file        -> silent "no daemon registry"
#   2. registry with no daemons -> silent "no daemons registered"
#   3. all daemons healthy     -> silent "all daemons healthy"
#   4. one daemon stopped      -> silent "all running daemons healthy;
#                                 intentionally stopped: <id>" (or "all
#                                 daemons intentionally stopped: <id>"
#                                 when none are running)
#   5. one daemon down         -> WAKE naming the daemons it covers;
#                                 the why is in the payload
#   6. daemon down but woken inside the cooldown -> silent "restart already in progress (cooldown)"
#   7. daemon process alive but heartbeat stale -> WAKE, payload reason "heartbeat stale"
#   8. daemon down and woken MAX_CONSECUTIVE_WAKES times in a row (seed
#      .wakes[<id>] in the state file) -> silent "gave up waking for <id>"
set -euo pipefail
# shellcheck source=/dev/null
source "$HATCH_HOOK_RUNTIME"

REGISTRY="{{REGISTRY_PATH}}"
WAKE_COOLDOWN_SECS="{{WAKE_COOLDOWN_SECS}}"
# Consecutive wakes for one daemon before the hook gives up on it (see the
# header). Override without editing the script: WATCHDOG_MAX_CONSECUTIVE_WAKES.
MAX_CONSECUTIVE_WAKES="${WATCHDOG_MAX_CONSECUTIVE_WAKES:-3}"

if ! command -v jq >/dev/null 2>&1; then
    silent "jq not installed; cannot read the daemon registry" '{}'
fi
if ! command -v pgrep >/dev/null 2>&1; then
    silent "pgrep not installed; cannot check daemon processes" '{}'
fi
if ! date -d "@0" +%s >/dev/null 2>&1; then
    silent "GNU date not available; cannot parse polled_at" '{}'
fi

case "$REGISTRY$WAKE_COOLDOWN_SECS" in
    *'{{'*) silent "watchdog placeholder not filled in — supervision not configured" '{}' ;;
esac
case "$WAKE_COOLDOWN_SECS" in
    ''|*[!0-9]*) silent "bad WAKE_COOLDOWN_SECS '$WAKE_COOLDOWN_SECS' (digits only) — supervision not configured" '{}' ;;
esac
case "$MAX_CONSECUTIVE_WAKES" in
    ''|*[!0-9]*|0) MAX_CONSECUTIVE_WAKES=3 ;;
esac
# Expand a leading ~ (a double-quoted placeholder value is not tilde-expanded).
REGISTRY="${REGISTRY/#\~/$HOME}"

state=$(hook_state_get 2>/dev/null \
    | jq -c 'if type == "object" then . else {} end
             | .waking |= (if type == "object" then . else {} end)
             | .wakes |= (if type == "object" then . else {} end)' 2>/dev/null) \
    || state='{}'
[ -n "$state" ] || state='{}'

now=$(date +%s)
dry_run=0; [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ] && dry_run=1

set_state() { if [ "$dry_run" -eq 0 ]; then hook_state_set "$1"; fi; }

if [ ! -f "$REGISTRY" ]; then
    silent "no daemon registry at $REGISTRY — supervision not configured" '{}'
fi
if ! jq -e '.daemons | type == "array"' "$REGISTRY" >/dev/null 2>&1; then
    silent "daemon registry unreadable — supervision not configured" '{}'
fi
if [ "$(jq -r '.daemons | length' "$REGISTRY")" -eq 0 ]; then
    silent "no daemons registered" '{}'
fi
if ! jq -e '.daemons | all(type == "object")' "$REGISTRY" >/dev/null 2>&1; then
    silent "daemon registry has a non-object entry" '{}'
fi
# Uniqueness is checked over the entries that HAVE the field; a missing id
# or pgrep is reported per entry below, not as a duplicate.
if ! jq -e '[.daemons[] | .id // empty] | (unique | length) == length' "$REGISTRY" >/dev/null 2>&1; then
    silent "daemon registry has duplicate daemon ids" '{}'
fi
if ! jq -e '[.daemons[] | .pgrep // empty] | (unique | length) == length' "$REGISTRY" >/dev/null 2>&1; then
    silent "daemon registry has duplicate pgrep patterns" '{}'
fi

# heartbeat_age <file> <field>: seconds since polled_at (ISO-8601 or epoch
# integer seconds). Prints one of: a non-negative integer age (a small
# negative skew, up to HEARTBEAT_SKEW_SECS, is clamped to 0 — the heartbeat
# may land after `now` was read); "absent" (file missing); "nofield" (the
# file is a JSON object with no polled_at key at all — a daemon predating
# the heartbeat rule, so the caller checks the process only);
# "unparseable" (anything else that cannot be trusted: an empty or
# non-JSON file, a non-object, a null/boolean/array/object value,
# epoch milliseconds, or a timestamp further in the future than the skew
# allows — a config/daemon problem the caller names, never counts healthy).
# Timestamps are parsed in jq, so no GNU date is needed.
# jq definition shared by the heartbeat and log-line timestamp parsers.
# shellcheck disable=SC2016
JQ_ISO='def iso_epoch:
    capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")
    | (.base + "Z" | fromdateiso8601) as $e
    | if .tz == "Z" then $e
      else (.tz | sub(":"; "")) as $z
        | ((($z[1:3] | tonumber) * 3600) + (($z[3:5] | tonumber) * 60)) as $off
        | if $z[0:1] == "+" then $e - $off else $e + $off end
      end;
'

HEARTBEAT_SKEW_SECS=60
heartbeat_age() {
    local file="$1" field="${2:-polled_at}"
    [ -f "$file" ] || { echo absent; return; }
    local out
    # jq prints "nofield", "unparseable" or an integer epoch; no output at
    # all (empty file) or a jq failure (invalid JSON) is unparseable too.
    # The if-condition suppresses set -e, so a failing jq is read here.
    if ! out=$(jq -r --arg f "$field" "$JQ_ISO"'
        if type != "object" then "unparseable"
        elif has($f) | not then "nofield"
        else .[$f] as $v
            | (if ($v | type) == "number" then $v | floor
               elif ($v | type) == "string" and ($v | test("^[0-9]+$")) then ($v | sub("^0+"; "") | if . == "" then 0 else tonumber end)
               elif ($v | type) == "string" then ($v | try iso_epoch catch null)
               else null end)
            | if type == "number" and . > 0 then tostring else "unparseable" end
        end' "$file" 2>/dev/null); then
        echo unparseable; return
    fi
    case "$out" in
        nofield|unparseable) echo "$out"; return ;;
        ''|*[!0-9]*) echo unparseable; return ;;
    esac
    local age=$((now - out))
    if [ "$age" -lt "-$HEARTBEAT_SKEW_SECS" ]; then
        echo unparseable   # far-future: epoch ms, or a clock that cannot be right
    elif [ "$age" -lt 0 ]; then
        echo 0
    else
        echo "$age"
    fi
}

# log_backoff <log_file> <stale_secs>: succeeds, printing "attempt N", when
# the daemon's log shows it alive and backing off: its LAST line is a
# poll_failed event (the daemon logs attempt and backoff_secs) newer than
# backoff_secs + stale_secs. stale_secs already covers poll interval + first
# backoff step + call timeout, so the sum outlasts the gap between two
# consecutive poll_failed lines at any backoff step. A log that is missing,
# unreadable, silent for longer, or ends in anything else fails: the
# caller treats the daemon as down.
log_backoff() {
    local file="$1" stale="$2" last fields ts bo attempt
    [ -f "$file" ] || return 1
    last=$(tail -n 1 "$file" 2>/dev/null) || return 1
    fields=$(printf '%s' "$last" | jq -r "$JQ_ISO"'
        if type == "object" and .event == "poll_failed" and (.ts | type) == "string"
           and (.backoff_secs | type) == "number" and .backoff_secs >= 0 and .backoff_secs < 86400
        then [(.ts | try iso_epoch catch 0), (.backoff_secs | floor),
              ((.attempt // 0) | if type == "number" then floor else 0 end)] | @tsv
        else empty end' 2>/dev/null) || return 1
    [ -n "$fields" ] || return 1
    IFS=$'\t' read -r ts bo attempt <<< "$fields"
    case "$ts$bo$attempt" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ts" -gt 0 ] || return 1
    [ $((now - ts)) -le $((bo + stale)) ] || return 1
    echo "attempt $attempt"
}

# anchored_ok <pattern>: succeeds only if the pattern is anchored ^...$ AND
# the anchors bind the whole pattern: no unparenthesised top-level `|`
# (^a|b$ anchors only the outer alternatives) and no escaped final `$`.
anchored_ok() {
    local p="$1" i c depth=0 esc=0 br=0 last=$((${#1} - 1))
    case "$p" in '^'*'$') ;; *) return 1 ;; esac
    for ((i = 0; i < ${#p}; i++)); do
        c="${p:i:1}"
        if [ "$esc" -eq 1 ]; then
            esc=0
            if [ "$i" -eq "$last" ]; then return 1; fi
            continue
        fi
        if [ "$br" -eq 1 ]; then
            if [ "$c" = "]" ]; then br=0; fi
            continue
        fi
        case "$c" in
            \\) esc=1 ;;
            '[') br=1 ;;
            '(') depth=$((depth + 1)) ;;
            ')') depth=$((depth - 1)) ;;
            '|') if [ "$depth" -le 0 ]; then return 1; fi ;;
        esac
    done
    return 0
}

down_json='{}'   # {id: reason} for daemons found down
stopped_list=""  # ids intentionally stopped
notes=""         # config problems worth naming in the reason (bad patterns)
healthy=0
healthy_ids=""   # ids seen healthy (wake count reset once healthy for a cooldown)
backing_off=""   # ids alive with a stale heartbeat but a log of recent poll_failed
stopped_ids=""   # ids intentionally stopped (wake count reset at once)

while IFS= read -r entry; do
    id=$(printf '%s' "$entry" | jq -r '.id')
    pgrep_pat=$(printf '%s' "$entry" | jq -r '.pgrep')
    hb_file=$(printf '%s' "$entry" | jq -r '.heartbeat_file // empty')
    hb_field=$(printf '%s' "$entry" | jq -r '.heartbeat_field // "polled_at"')
    stale=$(printf '%s' "$entry" | jq -r '.stale_secs // 0')
    stop_file=$(printf '%s' "$entry" | jq -r '.stop_file // empty')
    log_file=$(printf '%s' "$entry" | jq -r '.log_file // empty')
    # Expand a leading ~ in paths (jq returns the literal string).
    hb_file="${hb_file/#\~/$HOME}"; stop_file="${stop_file/#\~/$HOME}"; log_file="${log_file/#\~/$HOME}"

    # Validate the entry before acting on it. A missing id, a missing
    # pgrep pattern, or a heartbeat file with a missing/zero/non-numeric
    # stale_secs would silently degrade to process-only (fail toward
    # healthy) — all three are config errors, not down daemons.
    if [ -z "$id" ] || [ "$id" = "null" ]; then
        notes="${notes:+$notes; }registry entry without an id"; continue
    fi
    # Ids feed the space-separated wake list, so an id with whitespace
    # (or anything outside [A-Za-z0-9_.-]) would corrupt it — reject it
    # here instead of letting it through to the payload filter.
    case "$id" in
        *[!A-Za-z0-9_.-]*) notes="${notes:+$notes; }bad daemon id '$id'"; continue ;;
    esac
    if [ -z "$pgrep_pat" ] || [ "$pgrep_pat" = "null" ]; then
        notes="${notes:+$notes; }missing pgrep pattern for $id"; continue
    fi
    if [ -n "$hb_file" ]; then
        case "$stale" in
            ''|*[!0-9]*|0) notes="${notes:+$notes; }bad stale_secs for $id"; continue ;;
        esac
    fi

    if [ -n "$stop_file" ] && [ -f "$stop_file" ]; then
        stopped_list="$stopped_list $id"  # intentionally stopped — skip
        stopped_ids="$stopped_ids $id"
        continue
    fi

    # The pattern must be anchored at both ends. An unanchored pattern
    # matches the exec tool's background-session wrapper (a bash whose -c
    # argument contains the same script path) and reports a dead daemon
    # as alive — silent false-healthy, the worst failure for a watchdog.
    # An unanchored pattern is a config error, not a down daemon. The check
    # is deliberately conservative (see anchored_ok): an alternation must be
    # grouped, ^(a|b)$, so both anchors bind every branch.
    if ! anchored_ok "$pgrep_pat"; then
        notes="${notes:+$notes; }unanchored pgrep pattern for $id"; continue
    fi

    # pgrep exit 2 is an invalid pattern, not a dead daemon — skip the
    # entry and name it instead of waking on it. (The || guard matters:
    # this script runs under `set -e`, and a bare failing pgrep would
    # kill the whole poll instead of being read.)
    prc=0
    pgrep -f "$pgrep_pat" >/dev/null 2>&1 || prc=$?
    if [ "$prc" -eq 2 ]; then
        notes="${notes:+$notes; }invalid pgrep pattern for $id"
        continue
    elif [ "$prc" -ne 0 ]; then
        down_json=$(printf '%s' "$down_json" | jq -c --arg id "$id" '. + {($id): "process missing"}')
        continue
    fi

    if [ -n "$hb_file" ]; then
        age=$(heartbeat_age "$hb_file" "$hb_field")
        if [ "$age" = "absent" ]; then
            if [ -n "$log_file" ] && bo=$(log_backoff "$log_file" "$stale"); then
                healthy=$((healthy + 1)); backing_off="$backing_off $id($bo)"  # alive, source failing
            else
                down_json=$(printf '%s' "$down_json" | jq -c --arg id "$id" '. + {($id): "process alive but no heartbeat file"}')
            fi
        elif [ "$age" = "unparseable" ]; then
            notes="${notes:+$notes; }unparseable $hb_field for $id"  # not healthy, not woken
        elif [ "$age" != "nofield" ] && [ "$stale" -gt 0 ] && [ "$age" -gt "$stale" ]; then
            if [ -n "$log_file" ] && bo=$(log_backoff "$log_file" "$stale"); then
                healthy=$((healthy + 1)); backing_off="$backing_off $id($bo)"  # alive, source failing
            else
                down_json=$(printf '%s' "$down_json" | jq -c --arg id "$id" --argjson a "$age" '. + {($id): ("heartbeat stale (" + ($a|tostring) + "s old)")}')
            fi
        else
            healthy=$((healthy + 1))  # fresh heartbeat, or no polled_at yet (process-only)
            healthy_ids="$healthy_ids $id"
        fi
    else
        healthy=$((healthy + 1))  # process-only daemon
        healthy_ids="$healthy_ids $id"
    fi
done < <(jq -c '.daemons[]' "$REGISTRY")

# last_wake_of <id>: the daemon's last wake time as a plain integer. A
# non-number, a fractional or exponent value (jq would print 1E+3), or a
# timestamp in the future (the clock stepped back) must not break the
# arithmetic or pin the daemon in cooldown forever: non-numbers and future
# values read as 0 (never woken), fractions are floored.
last_wake_of() {
    printf '%s' "$state" | jq -r --arg d "$1" --argjson now "$now" \
        '(.waking[$d] // 0) | if type == "number" and . <= $now then (floor | if . < 0 then 0 else . end) else 0 end'
}

# Resetting a daemon's wake count and cooldown. An intentionally stopped
# daemon is reset at once (the owner stopped it; creating then removing the
# stop file re-arms it). A daemon seen healthy is reset only after it has
# stayed healthy for a full cooldown since its last wake: a flapping daemon
# (polls once, then dies) must keep its count and cooldown, or it would be
# woken forever and MAX_CONSECUTIVE_WAKES would never trip. Persist only
# when something actually changes.
clear_wake_state() { # clear_wake_state ID
    if [ "$(printf '%s' "$state" | jq -r --arg d "$1" '(has("wakes") and (.wakes | has($d))) or (has("waking") and (.waking | has($d)))')" = "true" ]; then
        state=$(printf '%s' "$state" | jq -c --arg d "$1" 'del(.wakes[$d], .waking[$d])')
        set_state "$state"
    fi
}
for id in $stopped_ids; do
    clear_wake_state "$id"
done
for id in $healthy_ids; do
    last_wake=$(last_wake_of "$id")
    if [ $((now - last_wake)) -ge "$WAKE_COOLDOWN_SECS" ]; then
        clear_wake_state "$id"
    fi
done

if [ "$(printf '%s' "$down_json" | jq 'length')" -eq 0 ]; then
    bo_note="${backing_off:+; alive but backing off after failed polls (do not restart):${backing_off}}"
    if [ -n "${stopped_list// }" ]; then
        if [ "$healthy" -gt 0 ]; then
            silent "all running daemons healthy; intentionally stopped:${stopped_list}${notes:+; $notes}${bo_note}" '{}'
        else
            silent "all daemons intentionally stopped:${stopped_list}${notes:+; $notes}" '{}'
        fi
    elif [ "$healthy" -eq 0 ]; then
        silent "no daemons supervised — config errors: ${notes:-none recorded}" '{}'
    elif [ -n "$notes" ]; then
        silent "$healthy healthy, others skipped: $notes${bo_note}" '{}'
    elif [ -n "$backing_off" ]; then
        silent "daemons alive; backing off after failed polls (source outage, not a restart case):${backing_off}" '{}'
    else
        silent "all daemons healthy" '{}'
    fi
fi

# Some daemon(s) down. Only wake for a daemon if we have not woken for it
# inside the cooldown — a recent wake means a worker is already on it — and
# not if it has already been woken MAX_CONSECUTIVE_WAKES times without ever
# being seen healthy (the restart is not holding; more turns will not fix it).
wake_list=""
gave_up=""
while IFS= read -r id; do
    last_wake=$(last_wake_of "$id")
    wakes=$(printf '%s' "$state" | jq -r --arg d "$id" '(.wakes[$d] // 0) | if type == "number" then ([., 0] | max | [., 1000000] | min | floor) else 0 end')
    if [ $((now - last_wake)) -lt "$WAKE_COOLDOWN_SECS" ]; then
        continue  # a worker is already on it
    elif [ "$wakes" -ge "$MAX_CONSECUTIVE_WAKES" ]; then
        gave_up="$gave_up $id"
    else
        wake_list="$wake_list $id"
        state=$(printf '%s' "$state" \
            | jq -c --arg d "$id" --argjson t "$now" --argjson w "$wakes" \
                '.waking[$d] = $t | .wakes[$d] = ($w + 1)')
    fi
done < <(printf '%s' "$down_json" | jq -r 'keys[]')

if [ -n "${gave_up// }" ]; then
    notes="${notes:+$notes; }gave up waking for${gave_up} after ${MAX_CONSECUTIVE_WAKES} consecutive wakes without recovery (check its error.json; stop-file toggle re-arms)"
fi

if [ -z "${wake_list// }" ]; then
    if [ -n "${gave_up// }" ]; then
        silent "daemon(s) down: ${notes}" '{}'
    fi
    silent "daemon(s) down but a restart is already in progress (cooldown)${notes:+; $notes}" '{}'
fi

set_state "$state"
# The payload names only the daemons this wake covers — a daemon already
# inside its cooldown is being restarted by another worker; naming it
# would instruct this worker to restart it too.
payload=$(printf '%s' "$down_json" | jq -c --arg wl "$wake_list" \
    '{down: (with_entries(select(.key as $k | ($wl | split(" ") | map(select(length > 0)) | index($k) != null))))}')
# The reason also names the intentionally-stopped daemons (context the
# worker/owner wants in the same line); the payload stays down-only, so a
# stopped daemon is never restarted by this wake.
stopped_reason=""
if [ -n "${stopped_list// }" ]; then
    stopped_reason="; intentionally stopped:${stopped_list}"
fi
wake "poller daemon(s) down: $wake_list${stopped_reason}${notes:+; $notes}" "$payload"
