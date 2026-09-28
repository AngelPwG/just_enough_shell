#!/usr/bin/env bash
# .cameras[] = {connector, output, tag, x, y, zoom, active}; x/y/zoom — СТРОКИ.
# zwwm шлёт x/y = ЛЕВЫЙ-ВЕРХНИЙ угол вьюпорта в мировых координатах
# (viewport.x = live_x - width/(2*scale) в camera.cpp). Для waypoint/jump-UI
# и MiniMap.qml (позиции окон — по ЦЕНТРУ) корректнее эмитить ЦЕНТР вьюпорта:
#   cx = x + width/(2*zoom),  cy = y + height/(2*zoom)
# Мир zwwm y-down; MiniMap.qml рисует centerY = (camY - posY)*mapZoom,
# поэтому y эмитим негированным.
set -u

if ! command -v zwwmctl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: zwwmctl or jq not found" >&2
    exit 1
fi

export LC_NUMERIC=C

THROTTLE_MS=100
PENDING=0
LAST_EMIT=0
PREV=""
OUTPUTS='{}'

JQ_FILTER='
  if (.cameras | length) == 0 then empty
  else (.cameras[] | select(.active) // .cameras[0]) as $cam
    | ($outputs[($cam.output | tostring)] // {width: 0, height: 0}) as $out
    | ($cam.zoom | tonumber) as $z
    | (($cam.x | tonumber) + ($out.width  / (2 * $z))) as $cx
    | (($cam.y | tonumber) + ($out.height / (2 * $z))) as $cy
    | "\($cx) \($cy * -1) \($cam.zoom)"
  end
'

refresh_outputs() {
    local outs
    outs=$(zwwmctl outputs -j 2>/dev/null | jq -c '
        [.outputs[]? | { key: (.id | tostring),
                         value: { width: .logical.width, height: .logical.height } }] | from_entries')
    [[ -n "$outs" ]] && OUTPUTS="$outs"
}

emit() {
    local out json now
    now=$(date +%s%3N)
    if (( now - LAST_EMIT < THROTTLE_MS )); then
        PENDING=1
        return
    fi
    LAST_EMIT=$now
    if ! out=$(zwwmctl states -j 2>/dev/null | jq -r --argjson outputs "$OUTPUTS" "$JQ_FILTER" 2>/dev/null); then
        PENDING=1
        return
    fi
    PENDING=0
    [[ -z "$out" ]] && return
    if ! json=$(awk -v line="$out" 'BEGIN{
        n = split(line, a, " ")
        if (n != 3) exit 1
        printf "{\"x\":\"%.4f\",\"y\":\"%.4f\",\"zoom\":\"%.4f\"}", a[1], a[2], a[3]
    }'); then
        PENDING=1
        return
    fi
    if [[ -n "$json" && "$json" != "$PREV" ]]; then
        printf '%s\n' "$json"
        PREV="$json"
    fi
}

stream_json() {
    while true; do
        refresh_outputs
        emit
        while true; do
            if IFS= read -r -t 0.3 line; then
                [[ -z "$line" ]] && continue
                case "$line" in
                    *'"event":"output"'*|*'"event": "output"'*|*'"event":"config"'*|*'"event": "config"'*)
                        refresh_outputs ;;
                esac
                emit
            else
                if (( $? > 128 )); then
                    if (( PENDING )); then LAST_EMIT=0; emit; fi
                else
                    break
                fi
            fi
        done < <(stdbuf -oL zwwmctl events camera output config -j 2>/dev/null)
        sleep 1
    done
}

case "$1" in
    "stream-json") stream_json ;;
    "--help") echo "Usage: $0 stream-json" ;;
    *) echo "Usage: $0 stream-json"; exit 1 ;;
esac
