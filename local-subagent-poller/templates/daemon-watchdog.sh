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
#   - A pgrep pattern that is not a valid regex (pgrep exits 2): that
#     entry is skipped and named in the reason. A bad pattern is a config
#     error, not a down daemon — waking on it would loop every cooldown.
#   - A pgrep pattern not anchored at both ends (^...$): that entry is
#     skipped and named in the reason. An unanchored pattern matches the
#     exec tool's background-session wrapper and reports a dead daemon
#     as alive — silent false-healthy, the worst failure for a watchdog.
#   - A heartbeat file that exists but carries no polled_at (a daemon
#     predating the heartbeat rule): process-only check. The file's mtime
#     is NEVER a liveness signal — an idle daemon whose state file only
#     updates on new items would look dead (the failure the 1.0.1
#     heartbeat rule fixed). A heartbeat file that does not exist at all
#     while the process is alive means the daemon never completed a poll:
#     that one is down.
#   - If this script dies mid-run, nothing is lost: hook state is only
#     written before a wake (`.waking[<id>] = now`), so a death before the
#     wake leaves the next poll free to retry, and a death after it only
#     delays the next wake by the cooldown.
#
# Dependencies: bash, jq, pgrep (procps), GNU date (for -d on polled_at).
# All are checked at startup; a missing one ends the poll silently with
# the reason (the hook log shows it). See README Requirements.
#
# stale_secs per daemon is poll interval + first backoff step + call
# timeout (design.md, "Daemon heartbeat and error markers"): 60+60+60=180
# for a 60s daemon, 10+10+10=30 for a 10s one.
#
# Placeholders:
#   {{REGISTRY_PATH}}      — absolute path to daemon-registry.json,
#                            e.g. ~/hooks/state/daemon-registry.json
#   {{WAKE_COOLDOWN_SECS}} — how long after a wake for one daemon to stay
#                            silent while its worker restarts it, e.g. 600
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
set -euo pipefail
# shellcheck source=/dev/null
source "$HATCH_HOOK_RUNTIME"

REGISTRY="{{REGISTRY_PATH}}"
WAKE_COOLDOWN_SECS="{{WAKE_COOLDOWN_SECS}}"

if ! command -v jq >/dev/null 2>&1; then
    silent "jq not installed; cannot read the daemon registry" '{}'
fi
if ! command -v pgrep >/dev/null 2>&1; then
    silent "pgrep not installed; cannot check daemon processes" '{}'
fi
if ! date -d "@0" +%s >/dev/null 2>&1; then
    silent "GNU date not available; cannot parse polled_at" '{}'
fi

state=$(hook_state_get 2>/dev/null \
    | jq -c 'if type == "object" then . else {} end' 2>/dev/null) \
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
if [ "$(jq -r '.daemons | map(.id) | unique | length' "$REGISTRY")" != "$(jq -r '.daemons | length' "$REGISTRY")" ]; then
    silent "daemon registry has duplicate daemon ids" '{}'
fi
if [ "$(jq -r '.daemons | map(.pgrep) | unique | length' "$REGISTRY")" != "$(jq -r '.daemons | length' "$REGISTRY")" ]; then
    silent "daemon registry has duplicate pgrep patterns" '{}'
fi
if ! jq -e '.daemons | all(type == "object")' "$REGISTRY" >/dev/null 2>&1; then
    silent "daemon registry has a non-object entry" '{}'
fi

# heartbeat_age <file> <field>: seconds since polled_at (ISO-8601 UTC).
# Prints an empty line when the file has no polled_at (daemon predates
# the heartbeat rule) — the caller then checks the process only. Prints
# -1 when the file is absent.
heartbeat_age() {
    local file="$1" field="${2:-polled_at}"
    [ -f "$file" ] || { echo -1; return; }
    local ts
    ts=$(jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null || echo "")
    [ -n "$ts" ] || { echo ""; return; }
    local t; t=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    [ "$t" -gt 0 ] && echo $((now - t)) || echo ""
}

down_json='{}'   # {id: reason} for daemons found down
stopped_list=""  # ids intentionally stopped
notes=""         # config problems worth naming in the reason (bad patterns)
healthy=0

while IFS= read -r entry; do
    id=$(printf '%s' "$entry" | jq -r '.id')
    pgrep_pat=$(printf '%s' "$entry" | jq -r '.pgrep')
    hb_file=$(printf '%s' "$entry" | jq -r '.heartbeat_file // empty')
    hb_field=$(printf '%s' "$entry" | jq -r '.heartbeat_field // "polled_at"')
    stale=$(printf '%s' "$entry" | jq -r '.stale_secs // 0')
    stop_file=$(printf '%s' "$entry" | jq -r '.stop_file // empty')
    # Expand a leading ~ in paths (jq returns the literal string).
    hb_file="${hb_file/#\~/$HOME}"; stop_file="${stop_file/#\~/$HOME}"

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
        continue
    fi

    # The pattern must be anchored at both ends. An unanchored pattern
    # matches the exec tool's background-session wrapper (a bash whose -c
    # argument contains the same script path) and reports a dead daemon
    # as alive — silent false-healthy, the worst failure for a watchdog.
    # An unanchored pattern is a config error, not a down daemon.
    case "$pgrep_pat" in
        '^'*'$') ;;
        *) notes="${notes:+$notes; }unanchored pgrep pattern for $id"; continue ;;
    esac

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
        if [ "$age" = "-1" ]; then
            down_json=$(printf '%s' "$down_json" | jq -c --arg id "$id" '. + {($id): "process alive but no heartbeat file"}')
        elif [ -n "$age" ] && [ "$stale" -gt 0 ] && [ "$age" -gt "$stale" ]; then
            down_json=$(printf '%s' "$down_json" | jq -c --arg id "$id" --argjson a "$age" '. + {($id): ("heartbeat stale (" + ($a|tostring) + "s old)")}')
        else
            healthy=$((healthy + 1))  # fresh heartbeat, or no polled_at yet (process-only)
        fi
    else
        healthy=$((healthy + 1))  # process-only daemon
    fi
done < <(jq -c '.daemons[]' "$REGISTRY")

if [ "$(printf '%s' "$down_json" | jq 'length')" -eq 0 ]; then
    if [ -n "${stopped_list// }" ]; then
        if [ "$healthy" -gt 0 ]; then
            silent "all running daemons healthy; intentionally stopped:${stopped_list}${notes:+; $notes}" '{}'
        else
            silent "all daemons intentionally stopped:${stopped_list}${notes:+; $notes}" '{}'
        fi
    else
        silent "all daemons healthy${notes:+; $notes}" '{}'
    fi
fi

# Some daemon(s) down. Only wake for a daemon if we have not woken for it
# inside the cooldown — a recent wake means a worker is already on it.
wake_list=""
while IFS= read -r id; do
    last_wake=$(printf '%s' "$state" | jq -r --arg d "$id" '.waking[$d] // 0')
    if [ $((now - last_wake)) -ge "$WAKE_COOLDOWN_SECS" ]; then
        wake_list="$wake_list $id"
        state=$(printf '%s' "$state" \
            | jq -c --arg d "$id" --argjson t "$now" '.waking[$d] = $t')
    fi
done < <(printf '%s' "$down_json" | jq -r 'keys[]')

if [ -z "${wake_list// }" ]; then
    silent "daemon(s) down but a restart is already in progress (cooldown)${notes:+; $notes}" '{}'
fi

set_state "$state"
# The payload names only the daemons this wake covers — a daemon already
# inside its cooldown is being restarted by another worker; naming it
# would instruct this worker to restart it too.
payload=$(printf '%s' "$down_json" | jq -c --arg wl "$wake_list" \
    '{down: (with_entries(select(.key as $k | ($wl | split(" ") | map(select(length > 0)) | index($k) != null))))}')
wake "poller daemon(s) down: $wake_list${notes:+; $notes}" "$payload"
