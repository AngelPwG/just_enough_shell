#!/usr/bin/env bash
# zwwm-теги: у каждого выхода ровно ОДИН просматриваемый тег.
# В states: .tags[] = {connector, output, active}, где active — НОМЕР тега
# (1..9), а не битовая маска (см. CompositorServer::tags() -> output->active_tag).
# wsN = "active", если тег N смотрит хотя бы на один выход.
#
# Вместо `zwwmctl listen` (полный снапшот на каждое событие window, которое
# летит на каждый commit любого клиента -> флод и зависание пайпа) слушаем
# тонкие сигналы `zwwmctl events` и пересобираем вывод из `states -j`
# с троттлингом, дедупом и flush по таймауту.
set -u

if ! command -v zwwmctl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: zwwmctl or jq not found" >&2
    exit 1
fi

THROTTLE_MS=120
PENDING=0
LAST_EMIT=0
PREV=""

JQ_FILTER='
  ([.tags[]?.active] | unique) as $viewed
  | reduce range(1; 10) as $i ({};
      . + {("ws" + ($i | tostring)): {
          class: (if ($viewed | index($i)) then "active" else "empty" end),
          icon: "" }})
'

emit() {
    local out now
    now=$(date +%s%3N)
    if (( now - LAST_EMIT < THROTTLE_MS )); then
        PENDING=1
        return
    fi
    LAST_EMIT=$now
    if ! out=$(zwwmctl states -j 2>/dev/null | jq -c "$JQ_FILTER" 2>/dev/null); then
        PENDING=1
        return
    fi
    PENDING=0
    if [[ -n "$out" && "$out" != "$PREV" ]]; then
        printf '%s\n' "$out"
        PREV="$out"
    fi
}

stream_tags() {
    while true; do
        emit
        while true; do
            if IFS= read -r -t 0.3 line; then
                [[ -z "$line" ]] && continue
                emit
            else
                if (( $? > 128 )); then   # таймаут read: flush пропущенных
                    if (( PENDING )); then LAST_EMIT=0; emit; fi
                else                       # EOF: zwwmctl умер, переподключаемся
                    break
                fi
            fi
        done < <(stdbuf -oL zwwmctl events tag output -j 2>/dev/null)
        sleep 1
    done
}

case "$1" in
    "stream-json") stream_tags ;;
    "--help") echo "Usage: $0 stream-json" ;;
    *) echo "Usage: $0 stream-json"; exit 1 ;;
esac
