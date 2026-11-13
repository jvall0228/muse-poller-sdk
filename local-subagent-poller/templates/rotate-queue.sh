#!/usr/bin/env bash
# rotate-queue.sh — archive a fully consumed queue and reset its cursor.
#
# Usage:
#   rotate-queue.sh --queue FILE --cursor FILE [--lock FILE] [--keep N]
#                   [--min-lines N] [--wait SECS]
#
# Env fallbacks: QUEUE_FILE, CURSOR_FILE, QUEUE_LOCK, ROTATE_KEEP,
# ROTATE_MIN_LINES, ROTATE_LOCK_WAIT_SECS. Defaults: --lock is queue.lock in
# the queue's directory, --keep 5, --min-lines 1000, --wait 30.
#
# Run it only from the worker that holds the worker lock, after catching up.
# It does nothing (exit 0) unless the cursor equals the queue's line count
# and the queue has at least --min-lines lines. Otherwise it:
#   1. takes an exclusive flock on the queue lock (producers take the same
#      lock around every append) and re-checks cursor == line count;
#   2. renames the queue to <name>.<UTC timestamp>.jsonl and recreates an
#      empty queue file;
#   3. writes cursor 0 atomically (temp file + mv);
#   4. releases the lock, then deletes all but the newest --keep archives.
# Prints the archive path on stdout when it rotated.
# Exit: 0 = rotated or nothing to do, 1 = failed (lock timeout, I/O error),
# 2 = usage error, 3 = flock(1) not installed.
# Logs are JSON lines on stderr: {"ts","level","event",...}.
set -euo pipefail

QUEUE="${QUEUE_FILE:-}"
CURSOR="${CURSOR_FILE:-}"
QLOCK="${QUEUE_LOCK:-}"
KEEP="${ROTATE_KEEP:-5}"
MIN_LINES="${ROTATE_MIN_LINES:-1000}"
WAIT="${ROTATE_LOCK_WAIT_SECS:-30}"

jesc() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

log() {
    local level=$1 event=$2 kv out
    shift 2
    out="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"$level\",\"event\":\"$(jesc "$event")\""
    for kv in "$@"; do
        out+=",\"$(jesc "${kv%%=*}")\":\"$(jesc "${kv#*=}")\""
    done
    printf '%s}\n' "$out" >&2
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; }
die_usage() { log error usage "detail=$1"; usage; exit 2; }
is_int() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --queue|--cursor|--lock|--keep|--min-lines|--wait)
            [ $# -ge 2 ] || die_usage "$1 needs a value"
            case $1 in
                --queue) QUEUE=$2 ;; --cursor) CURSOR=$2 ;; --lock) QLOCK=$2 ;;
                --keep) KEEP=$2 ;; --min-lines) MIN_LINES=$2 ;; --wait) WAIT=$2 ;;
            esac
            shift 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done
[ -n "$QUEUE" ] || die_usage "queue file not set (--queue)"
[ -n "$CURSOR" ] || die_usage "cursor file not set (--cursor)"
for v in "$KEEP" "$MIN_LINES" "$WAIT"; do
    is_int "$v" || die_usage "numeric setting is not a non-negative integer: $v"
done
dir=$(dirname "$QUEUE")
[ -n "$QLOCK" ] || QLOCK="$dir/queue.lock"
if ! command -v flock >/dev/null 2>&1; then
    log error flock_missing "hint=install util-linux flock"
    exit 3
fi

count_lines() { if [ -f "$QUEUE" ]; then wc -l < "$QUEUE" | tr -d ' '; else echo 0; fi; }
read_cursor() {
    local c=0
    if [ -f "$CURSOR" ]; then c=$(tr -d ' \n' < "$CURSOR" 2>/dev/null || echo 0); fi
    case $c in ''|*[!0-9]*) c=0 ;; esac
    echo "$c"
}

# Cheap check before touching the lock.
lines=$(count_lines); cursor=$(read_cursor)
if [ "$lines" -eq 0 ] || [ "$lines" -lt "$MIN_LINES" ] || [ "$cursor" -ne "$lines" ]; then
    log info rotate_skipped "lines=$lines" "cursor=$cursor" "min_lines=$MIN_LINES"
    exit 0
fi

mkdir -p "$(dirname "$QLOCK")"
exec 9>>"$QLOCK"
if ! flock -x -w "$WAIT" 9; then
    log error queue_lock_timeout "lock=$QLOCK" "waited=$WAIT"
    exit 1
fi

# Re-check under the lock: a producer may have appended while we waited.
lines=$(count_lines); cursor=$(read_cursor)
if [ "$lines" -eq 0 ] || [ "$lines" -lt "$MIN_LINES" ] || [ "$cursor" -ne "$lines" ]; then
    log info rotate_skipped_under_lock "lines=$lines" "cursor=$cursor"
    exit 0
fi

base=$(basename "$QUEUE")
stem=${base%.jsonl}
ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="$dir/$stem.$ts.jsonl"
while [ -e "$dest" ]; do   # keep names unique and sortable
    sleep 1
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$dir/$stem.$ts.jsonl"
done

mv "$QUEUE" "$dest"
: >> "$QUEUE"   # recreate so watchers never see the file vanish
tmp=$(mktemp "$CURSOR.XXXXXX")
if printf '0' > "$tmp" && mv -f "$tmp" "$CURSOR"; then
    :
else
    rm -f "$tmp"
    mv -f "$dest" "$QUEUE"   # roll back: queue and cursor stay consistent
    log error cursor_write_failed "cursor=$CURSOR"
    exit 1
fi
exec 9>&-
log info rotated "archive=$dest" "lines=$lines"
echo "$dest"

# Prune: names embed a UTC timestamp, so glob order is chronological.
archives=("$dir/$stem".[0-9]*T[0-9]*Z.jsonl)
if [ -e "${archives[0]}" ]; then
    n=${#archives[@]}
    i=0
    while [ "$i" -lt $((n - KEEP)) ]; do
        rm -f "${archives[$i]}"
        log info archive_pruned "archive=${archives[$i]}"
        i=$((i + 1))
    done
fi
