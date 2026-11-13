#!/usr/bin/env bash
# check-leaks.sh — fail when files contain deployment-specific strings.
#
# Usage: scripts/check-leaks.sh        (run from anywhere; checks the repo)
#
# Flags, per file:line: absolute home paths, email addresses, chat-style IDs,
# internal ticket keys, and any term listed in an optional, untracked
# .leak-terms file at the repo root (one term per line, case-insensitive,
# blank lines and lines starting with # ignored).
#
# Allowed: noreply@ addresses, example.com / example.org addresses, and
# well-known standard names that look like ticket keys (ISO, SHA, RFC, ...).
# Skipped: .git, LICENSE, lockfiles, node_modules, caches, binary files.
#
# Exit: 0 clean, 1 hits found, 2 usage or environment error. Needs grep -P.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

if ! echo x | grep -P x >/dev/null 2>&1; then
    echo "check-leaks: grep -P (PCRE) is required" >&2
    exit 2
fi

files=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(git ls-files -co --exclude-standard -z)
else
    while IFS= read -r -d '' f; do files+=("${f#./}"); done \
        < <(find . -type f -not -path './.git/*' -print0)
fi

keep=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    case $f in
        LICENSE|*/LICENSE|.git/*|*/node_modules/*|node_modules/*) continue ;;
        */__pycache__/*|*/.pytest_cache/*|*/.ruff_cache/*) continue ;;
        .pytest_cache/*|.ruff_cache/*|__pycache__/*) continue ;;
        bun.lock|bun.lockb|package-lock.json|*/bun.lock|*/package-lock.json) continue ;;
        .leak-terms) continue ;;
    esac
    keep+=("$f")
done
[ "${#keep[@]}" -gt 0 ] || { echo "check-leaks: no files to check"; exit 0; }

report() { # report RULE  (reads grep -nH output on stdin)
    local rule=$1 line
    while IFS= read -r line; do
        printf '%s: [%s] %s\n' "${line%%:*}:$(cut -d: -f2 <<<"$line")" "$rule" \
            "$(cut -d: -f3- <<<"$line" | cut -c1-160)"
    done
}

scan() { # scan RULE PCRE  [ALLOW_PCRE]; with ALLOW, prints only the matched token
    local rule=$1 re=$2 allow=${3:-}
    if [ -n "$allow" ]; then
        grep -noHIP -- "$re" "${keep[@]}" 2>/dev/null | grep -vP -- "$allow" | report "$rule"
    else
        grep -nHIP -- "$re" "${keep[@]}" 2>/dev/null | report "$rule"
    fi
}

out=$(
    scan home-path '/(?:home|Users)/[A-Za-z0-9._-]+/'
    scan email '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
        '(?:\bnoreply@|@example\.(?:com|org)\b)'
    scan chat-id '\b(?=[A-Z0-9]*[0-9])[UCWG][A-Z0-9]{8,}\b'
    scan ticket-key '\b(?!(?:ISO|SHA|RFC|UTF|CVE|CWE|PEP|BCP|STD|IEEE|ECMA|ES|TLS|AES|MD|PKCS|WCAG|ADR)-)[A-Z]{2,}-[0-9]{3,}\b'
    if [ -f .leak-terms ]; then
        terms=$(grep -vE '^[[:space:]]*(#|$)' .leak-terms || true)
        if [ -n "$terms" ]; then
            printf '%s\n' "$terms" > "${TMPDIR:-/tmp}/.leak-terms.$$"
            grep -nHIiF -f "${TMPDIR:-/tmp}/.leak-terms.$$" -- "${keep[@]}" 2>/dev/null | report term
            rm -f "${TMPDIR:-/tmp}/.leak-terms.$$"
        fi
    fi
)

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "check-leaks: $(printf '%s\n' "$out" | wc -l | tr -d ' ') hit(s)" >&2
    exit 1
fi
echo "check-leaks: clean (${#keep[@]} files)"
