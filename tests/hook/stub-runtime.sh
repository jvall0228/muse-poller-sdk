#!/usr/bin/env bash
# stub-runtime.sh — file-backed stand-in for the host hook runtime.
# Sourced by hook-watch.sh via $HATCH_HOOK_RUNTIME. Needs $STUB_DIR.
#   hook_state_get / hook_state_set  -> $STUB_DIR/state.json
#   silent REASON JSON / wake REASON JSON -> appended to $STUB_DIR/calls as
#   "<kind>\t<reason>\t<json>", then the hook exits (as the real runtime does).

hook_state_get() {
    if [ -f "$STUB_DIR/state.json" ]; then cat "$STUB_DIR/state.json"; else echo '{}'; fi
}

hook_state_set() {
    printf '%s' "$1" > "$STUB_DIR/state.json"
}

silent() {
    printf 'silent\t%s\t%s\n' "$1" "$2" >> "$STUB_DIR/calls"
    exit 0
}

wake() {
    printf 'wake\t%s\t%s\n' "$1" "$2" >> "$STUB_DIR/calls"
    exit 0
}
