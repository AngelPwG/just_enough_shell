#!/usr/bin/env bash
# state toplevel-а: 1 | (focused ? 4 : 0) — бит 4 = activated.
# Показываем app_id (коротко), а не title.
set -u

if ! command -v zwwmctl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: zwwmctl or jq not found" >&2
    exit 1
fi

THROTTLE_MS=150
PENDING=0
LAST_EMIT=0
PREV=""

JQ_FILTER='
  [.clients[]? | select(((.state // 0) / 4 | floor) % 2 == 1) | .app_id][0] // empty
'

emit() {
    local out now
    now=$(date +%s%3N)
    if (( now - LAST_EMIT < THROTTLE_MS )); then
        PENDING=1
        return
    fi
    LAST_EMIT=$now
    if ! out=$(zwwmctl states -j 2>/dev/null | jq -r "$JQ_FILTER" 2>/dev/null); then
        PENDING=1
        return
    fi
    PENDING=0
    if [[ -n "$out" && "$out" != "$PREV" ]]; then
        printf '%s\n' "$out"
        PREV="$out"
    fi
}

stream_window() {
    while true; do
        emit
        while true; do
            if IFS= read -r -t 0.3 line; then
                [[ -z "$line" ]] && continue
                emit
            else
                if (( $? > 128 )); then
                    if (( PENDING )); then LAST_EMIT=0; emit; fi
                else
                    break
                fi
            fi
        done < <(stdbuf -oL zwwmctl events window -j 2>/dev/null)
        sleep 1
    done
}

case "$1" in
    "stream-window") stream_window ;;
    "--help") echo "Usage: $0 stream-window" ;;
    *) echo "Usage: $0 stream-window"; exit 1 ;;
esac
