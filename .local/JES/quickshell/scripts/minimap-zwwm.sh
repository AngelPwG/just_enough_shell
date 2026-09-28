#!/usr/bin/env bash
# zwwm отдаёт toplevel-ы в VIEW-координатах (tile_bounds из canvas_view_bounds):
# tile = origin + (world - camTopLeft) * zoom. MiniMap.qml сам вычитает камеру:
#   centerX = (posX - camX) * mapZoom + centerX
#   centerY = (camY - posY) * mapZoom + centerY,  mapZoom = camZoom/20
# Поэтому эмитим МИРОВЫЕ координаты центра окна (обратный transform через
# камеру его выхода), y негирован (camera-zwwm.sh шлёт camY с минусом).
# origin = logical origin выхода (workarea без резерваций layer-shell; сдвиг
# ~высота_панели/zoom на карте — доли пикселя, пренебрежимо).
set -u

if ! command -v zwwmctl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: zwwmctl or jq not found" >&2
    exit 1
fi

THROTTLE_MS=150
PENDING=0
LAST_EMIT=0
PREV=""
OUTPUTS='{}'

JQ_FILTER='
  . as $state
  | ($origins) as $o
  | { windows:
      [ $state.clients[]?
        | . as $w
        | ([ $state.cameras[]? | select(.output == $w.output) ] | first) as $cam
        | if $cam == null then empty
          else
            ($o[($w.output | tostring)] // {x: 0, y: 0}) as $out
            | ($cam.zoom | tonumber) as $z
            | (($cam.x | tonumber) + (($w.x + $w.width  / 2 - $out.x) / $z)) as $cx
            | (($cam.y | tonumber) + (($w.y + $w.height / 2 - $out.y) / $z)) as $cy
            | { position: [ $cx, ($cy * -1) ],
                size: [ ($w.width / $z), ($w.height / $z) ],
                id: $w.id,
                app_id: $w.app_id,
                title: $w.title,
                is_focused: (((( $w.state // 0) / 4) | floor) % 2 == 1) }
          end
      ] }
'

refresh_outputs() {
    local origins
    origins=$(zwwmctl outputs -j 2>/dev/null | jq -c '
        [.outputs[]? | { key: (.id | tostring),
                         value: { x: .logical.x, y: .logical.y } }] | from_entries')
    [[ -n "$origins" ]] && OUTPUTS="$origins"
}

emit() {
    local out now
    now=$(date +%s%3N)
    if (( now - LAST_EMIT < THROTTLE_MS )); then
        PENDING=1
        return
    fi
    LAST_EMIT=$now
    if ! out=$(zwwmctl states -j 2>/dev/null | jq -c --argjson origins "$OUTPUTS" "$JQ_FILTER" 2>/dev/null); then
        PENDING=1
        return
    fi
    PENDING=0
    if [[ -n "$out" && "$out" != "$PREV" ]]; then
        printf '%s\n' "$out"
        PREV="$out"
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
        done < <(stdbuf -oL zwwmctl events window camera output config -j 2>/dev/null)
        sleep 1
    done
}

case "$1" in
    "stream-json") stream_json ;;
    "--help") echo "Usage: $0 stream-json" ;;
    *) echo "Usage: $0 stream-json"; exit 1 ;;
esac
