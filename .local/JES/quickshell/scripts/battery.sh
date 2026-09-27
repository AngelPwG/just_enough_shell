#!/usr/bin/env bash

BAT=""
ITS_LAPTOP=false

for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] && { BAT="$b"; ITS_LAPTOP=true; break; }
done

emit_json() {
    local status="n/a" capacity=0
    local need_charging=false
    local need_tests=false

    if [ -n "$BAT" ]; then
        status=$(cat "$BAT/status" 2>/dev/null)
        capacity=$(cat "$BAT/capacity" 2>/dev/null)

        # --- need_tests ---
        local full design
        full=$(cat "$BAT/charge_full" 2>/dev/null || cat "$BAT/energy_full" 2>/dev/null)
        design=$(cat "$BAT/charge_full_design" 2>/dev/null || cat "$BAT/energy_full_design" 2>/dev/null)
        if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ]; then
            [ $(( full * 100 / design )) -lt 75 ] && need_tests=true
        fi

        # --- need_charging (только при разрядке) ---
        if [ "$status" = "Discharging" ]; then
            local power now voltage remaining_sec
            power=$(cat "$BAT/power_now" 2>/dev/null)
            now=$(cat "$BAT/energy_now" 2>/dev/null)

            if [ -n "$now" ] && [ -n "$power" ] && [ "$power" -gt 0 ]; then
                remaining_sec=$(( now * 3600 / power ))
                [ "$remaining_sec" -lt 1200 ] && need_charging=true
            elif [ -n "$power" ] && [ "$power" -gt 0 ]; then
                now=$(cat "$BAT/charge_now" 2>/dev/null)
                voltage=$(cat "$BAT/voltage_now" 2>/dev/null)
                if [ -n "$now" ] && [ -n "$voltage" ] && [ "$voltage" -gt 0 ]; then
                    remaining_sec=$(( now * voltage * 3600 / power / 1000000 ))
                    [ "$remaining_sec" -lt 1200 ] && need_charging=true
                fi
            fi
        fi
    fi

    printf '{"its_laptop":%s,"status":"%s","capacity":%s,"need_charging":%s,"need_tests":%s}\n' \
        "$ITS_LAPTOP" "$status" "$capacity" "$need_charging" "$need_tests"
}

emit_json

# Мониторим, только если батарея найдена
[ -n "$BAT" ] && command -v inotifywait >/dev/null && {
    inotifywait -m -e modify --format '%f' "$BAT" 2>/dev/null |
    while read -r file; do
        case "$file" in
            capacity|status|charge_now|energy_now|power_now|charge_full|energy_full)
                emit_json
                ;;
        esac
    done
}
