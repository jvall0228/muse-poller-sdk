#!/usr/bin/env bash
# lock-holder.sh — hold, release and inspect a poller worker lock.
#
# Usage:
#   lock-holder.sh take    [--lock FILE] [--alive FILE] [--stale SECS]
#   lock-holder.sh release [--lock FILE]
#   lock-holder.sh status  [--lock FILE] [--alive FILE] [--stale SECS]
#
# Settings may also come from the environment: LOCK_FILE, ALIVE_FILE,
# LOCK_STALE_SECS (flags win). Tuning (rarely needed): LOCK_POLL_SECS
# (holder check interval, default 2), LOCK_SETTLE_SECS (wait after each
# take attempt, default 1), LOCK_RELEASE_WAIT_SECS (default 10).
#
# take     Touches the alive file, then starts a background holder that takes
#          an exclusive non-blocking flock on the lock file and keeps it until
#          <lock>.release exists or the alive file is older than the stale
#          limit. A leftover .release is removed once the lock is taken.
#          Retries 3 times (the hook probes the lock for an instant and can
#          collide). Prints the holder PID on stdout.
#          Exit 0 = taken, 1 = held by another worker.
# release  Touches <lock>.release, waits up to 10s for the lock to free, then
#          removes .release. Exit 0 = freed, 1 = still held (.release is left
#          in place so the holder still sees it).
# status   Prints one JSON line, e.g. {"held":true,"lock":"...",...}. Exit 0.
#
# Other exits: 2 = usage error, 3 = flock(1) not installed.
# Logs are JSON lines on stderr: {"ts","level","event",...}.
# Do not `kill` the holder's flock to release: use `release`.
set -uo pipefail

LOCK="${LOCK_FILE:-}"
ALIVE="${ALIVE_FILE:-}"
STALE="${LOCK_STALE_SECS:-900}"
POLL="${LOCK_POLL_SECS:-2}"
SETTLE="${LOCK_SETTLE_SECS:-1}"
RELEASE_WAIT="${LOCK_RELEASE_WAIT_SECS:-10}"

jesc() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# log LEVEL EVENT [key=value ...] -> JSON line on stderr
log() {
    local level=$1 event=$2 kv out
    shift 2
    out="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"$level\",\"event\":\"$(jesc "$event")\""
    for kv in "$@"; do
        out+=",\"$(jesc "${kv%%=*}")\":\"$(jesc "${kv#*=}")\""
    done
    printf '%s}\n' "$out" >&2
}

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

die_usage() { log error usage "detail=$1"; usage; exit 2; }

mtime() {
    if stat -c %Y / >/dev/null 2>&1; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

require_flock() {
    if ! command -v flock >/dev/null 2>&1; then
        log error flock_missing "hint=install util-linux flock"
        exit 3
    fi
}

is_int() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Runs inside the flock'd process. $1 lock, $2 alive, $3 stale, $4 poll.
# Self-contained so it works under plain sh.
# shellcheck disable=SC2016
HOLDER_SH='
rel="$1.release"
rm -f "$rel"
if stat -c %Y / >/dev/null 2>&1; then fmt=gnu; else fmt=bsd; fi
mtime() {
    if [ "$fmt" = gnu ]; then stat -c %Y "$1"; else stat -f %m "$1"; fi 2>/dev/null || echo 0
}
while [ ! -e "$rel" ] && [ $(( $(date +%s) - $(mtime "$2") )) -le "$3" ]; do
    sleep "$4"
done
'

cmd_take() {
    local pid="" i
    require_flock
    mkdir -p "$(dirname "$LOCK")" "$(dirname "$ALIVE")" || { log error mkdir_failed; return 1; }
    touch "$ALIVE"
    for i in 1 2 3; do
        nohup flock -n "$LOCK" sh -c "$HOLDER_SH" holder "$LOCK" "$ALIVE" "$STALE" "$POLL" \
            </dev/null >/dev/null 2>&1 &
        pid=$!
        sleep "$SETTLE"
        if kill -0 "$pid" 2>/dev/null; then
            log info lock_taken "pid=$pid" "lock=$LOCK" "attempt=$i"
            echo "$pid"
            return 0
        fi
        log warn take_attempt_failed "attempt=$i"
    done
    log error lock_held_by_other "lock=$LOCK"
    return 1
}

cmd_release() {
    local i freed=0
    require_flock
    touch "$LOCK.release"
    for ((i = 0; i <= RELEASE_WAIT; i++)); do
        if flock -n "$LOCK" true 2>/dev/null; then freed=1; break; fi
        sleep 1
    done
    if [ "$freed" -eq 1 ]; then
        rm -f "$LOCK.release"
        log info lock_released "lock=$LOCK"
        return 0
    fi
    log error release_timeout "lock=$LOCK" "waited=$RELEASE_WAIT"
    return 1
}

cmd_status() {
    local held=false age=null stale_alive=null release=false now m
    require_flock
    if [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; then held=true; fi
    if [ -e "$ALIVE" ]; then
        now=$(date +%s); m=$(mtime "$ALIVE")
        age=$((now - m))
        if [ "$age" -gt "$STALE" ]; then stale_alive=true; else stale_alive=false; fi
    fi
    if [ -e "$LOCK.release" ]; then release=true; fi
    printf '{"held":%s,"lock":"%s","alive_age_secs":%s,"alive_stale":%s,"stale_secs":%s,"release_pending":%s}\n' \
        "$held" "$(jesc "$LOCK")" "$age" "$stale_alive" "$STALE" "$release"
    return 0
}

[ $# -ge 1 ] || die_usage "missing subcommand"
sub=$1; shift
case $sub in
    -h|--help|help) usage; exit 0 ;;
    take|release|status) ;;
    *) die_usage "unknown subcommand: $sub" ;;
esac
while [ $# -gt 0 ]; do
    case $1 in
        --lock)  [ $# -ge 2 ] || die_usage "--lock needs a value"; LOCK=$2; shift 2 ;;
        --alive) [ $# -ge 2 ] || die_usage "--alive needs a value"; ALIVE=$2; shift 2 ;;
        --stale) [ $# -ge 2 ] || die_usage "--stale needs a value"; STALE=$2; shift 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done
[ -n "$LOCK" ] || die_usage "lock file not set (--lock or LOCK_FILE)"
if [ "$sub" != release ]; then
    [ -n "$ALIVE" ] || die_usage "alive file not set (--alive or ALIVE_FILE)"
fi
for v in "$STALE" "$POLL" "$SETTLE" "$RELEASE_WAIT"; do
    is_int "$v" || die_usage "numeric setting is not a non-negative integer: $v"
done

"cmd_$sub"
