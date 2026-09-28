#!/usr/bin/env bash
# .keyboard в states: {name, group} либо {layout: "us,ru", group}.
# name от xkb бывает "English (US)" / "Russian" / "us" — вытаскиваем код.
set -u

if ! command -v zwwmctl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: zwwmctl or jq not found" >&2
    exit 1
fi

THROTTLE_MS=200
PENDING=0
LAST_EMIT=0
PREV=""

JQ_FILTER='
  if .keyboard then
    (.keyboard.group // 0) as $g
    | (.keyboard.layout // .keyboard.name // "") as $layouts
    | (($layouts | split(","))[$g] // $layouts) as $entry
    | ($entry | gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $n
    | ([$n | match("\\(([a-z]+)\\)")] | first? | .captures[0].string)
      // (if ($n | length) <= 3 then $n else $n[0:2] end)
    | ascii_upcase | ({"US":"EN","GB":"EN"}[.]) // .
  else empty end
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

stream_layout() {
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
        done < <(stdbuf -oL zwwmctl events keyboard -j 2>/dev/null)
        sleep 1
    done
}

case "$1" in
    "stream-layout") stream_layout ;;
    "--help") echo "Usage: $0 stream-layout" ;;
    *) echo "Usage: $0 stream-layout"; exit 1 ;;
esac
