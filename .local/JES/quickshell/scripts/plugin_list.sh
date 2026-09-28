#!/usr/bin/env bash

set -uo pipefail

CONFIG_FILE="$HOME/.config/JES/config.toml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Ошибка: файл конфига не найден: $CONFIG_FILE" >&2
    exit 1
fi

# --- Парсим config.toml один раз в JSON для доступа к [[plugin]] блокам ---
CONFIG_JSON="{}"
if command -v taplo &>/dev/null; then
    CONFIG_JSON=$(taplo get -f "$CONFIG_FILE" -o json 2>/dev/null || echo "{}")
fi

# --- Директория плагинов из конфига ---
DIR=$(grep -E '^[[:space:]]*directory[[:space:]]*=' "$CONFIG_FILE" \
    | head -1 | awk -F '=' '{print $2}' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
DIR="${DIR/#\~/$HOME}"

if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    echo "Ошибка: директория плагинов не найдена: $DIR" >&2
    exit 1
fi

# --- enableFolders (default: true) ---
ENABLE_FOLDERS=$(grep -E '^[[:space:]]*enableFolders[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null \
    | head -1 | awk -F '=' '{print $2}' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//' | tr -d "'")
ENABLE_FOLDERS="${ENABLE_FOLDERS:-true}"

# --- Пути ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_ROOT="$HOME/.cache/JES"
OUTPUT_FILE="$CACHE_ROOT/JES_plugin_list.json"
CACHE_DIR="$CACHE_ROOT/cached_plugins"
CACHE_STAMP="$CACHE_ROOT/.plugins_fingerprint"
BLACKLIST_FILE="$CACHE_ROOT/blacklist"

mkdir -p "$CACHE_ROOT"

# --- Разбор аргументов ---
if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    HOST_VERSION="$1"
    CMD="${2:-build}"
    CMD_EXTRA="${3:-}"
else
    HOST_VERSION="${JES_HOST_VERSION:-0.2.1}"
    CMD="${1:-build}"
    CMD_EXTRA="${2:-}"
fi

if ! command -v jq &>/dev/null; then
    echo "Ошибка: jq не установлен" >&2
    exit 1
fi

# =====================================================================
#  Identity helpers
# =====================================================================

# getPlugin <manifest_path>
# Возвращает uuid из manifest.json, либо name как fallback.
getPlugin() {
    local manifest="$1"
    local uuid
    uuid=$(jq -r '.uuid // ""' "$manifest" 2>/dev/null)
    if [[ -n "$uuid" && "$uuid" != "null" ]]; then
        printf '%s' "$uuid"
    else
        jq -r '.name // ""' "$manifest" 2>/dev/null
    fi
}

# getPluginName <manifest_path>
getPluginName() {
    local manifest="$1"
    jq -r '.name // ""' "$manifest" 2>/dev/null
}

# =====================================================================
#  Хелперы
# =====================================================================

# get_plugin_state <search>
# search — uuid или name; ищем по обоим полям [[plugin]]-блока.
get_plugin_state() {
    local search="$1"
    awk -v n="$search" '
        BEGIN { state = "unset"; found = 0 }
        /^[[:space:]]*\[\[plugin\]\]/ { in_plugin = 1; cur_matched = 0; next }
        /^[[:space:]]*\[/ && !/^[[:space:]]*\[\[plugin\]\]/ { in_plugin = 0 }
        in_plugin && /^[[:space:]]*(name|uuid)[[:space:]]*=/ {
            val = $0
            sub(/^[[:space:]]*(name|uuid)[[:space:]]*=[[:space:]]*/, "", val)
            gsub(/^"|"$/, "", val)
            if (val == n) { cur_matched = 1; found = 1 }
        }
        in_plugin && cur_matched && /^[[:space:]]*active[[:space:]]*=/ {
            val = $0
            sub(/^[[:space:]]*active[[:space:]]*=[[:space:]]*/, "", val)
            gsub(/^"|"$/, "", val)
            state = tolower(val) == "true" ? "true" : "false"
        }
        END {
            if (found == 1 && state == "unset") state = "false"
            print state
        }
    ' "$CONFIG_FILE" | tr -d '\n\r'
}

# get_plugin_config_json <search>  — search может быть uuid или name.
# Возвращает JSON-объект со всеми кастомными ключами из [[plugin]]-блока
# (кроме name, uuid, active). Пустой объект если ключей нет.
get_plugin_config_json() {
    local search="$1"
    if [[ "$CONFIG_JSON" == "{}" ]]; then
        echo "{}"
        return
    fi
    echo "$CONFIG_JSON" | jq -c --arg n "$search" '
        (.plugin // [])
        | map(select(.name == $n or .uuid == $n))[0] // {}
        | del(.name, .uuid, .active)
    ' 2>/dev/null || echo "{}"
}

is_blacklisted() {
    local ident="$1"
    [[ -z "$ident" ]] && return 1
    [[ ! -f "$BLACKLIST_FILE" ]] && return 1
    grep -qxF "$ident" "$BLACKLIST_FILE"
}

check_compatibility() {
    local host_ver="$1"
    local plugin_ver="$2"

    IFS='.' read -r h_major h_minor h_patch <<< "$host_ver"
    IFS='.' read -r p_major p_minor p_patch <<< "$plugin_ver"

    if [[ -z "$h_major" || -z "$h_minor" || -z "$h_patch" ||
          -z "$p_major" || -z "$p_minor" || -z "$p_patch" ]]; then
        echo "INCOMPATIBLE:Invalid version format"
        return 1
    fi

    (( h_minor > 50 || h_patch > 50 )) && echo "WARNING:Host minor/patch > 50" >&2
    (( p_minor > 50 || p_patch > 50 )) && echo "WARNING:Plugin minor/patch > 50" >&2

    if (( h_major != p_major )); then
        echo "INCOMPATIBLE:Major mismatch (host $h_major, plugin $p_major)"
        return 1
    fi

    local warning=""
    local last_breaking=$(( (h_minor / 5) * 5 ))
    if (( last_breaking > 0 && p_minor < last_breaking )); then
        warning="Plugin version $plugin_ver is behind the latest breaking release $h_major.$last_breaking.0, please update."
    fi

    echo "COMPATIBLE:$warning"
    return 0
}

_plugins_fingerprint() {
    local src_fp script_mtime cfg_mtime bl_mtime
    src_fp=$(find "$DIR" \( -type f -o -type l \) -printf '%T@ %s %p\n' 2>/dev/null \
        | sort | md5sum | awk '{print $1}')
    script_mtime=$(stat -c '%Y' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0)
    cfg_mtime=$(stat -c '%Y' "$CONFIG_FILE" 2>/dev/null || echo 0)
    bl_mtime=$(stat -c '%Y' "$BLACKLIST_FILE" 2>/dev/null || echo 0)
    echo "$src_fp-$script_mtime-$cfg_mtime-$bl_mtime"
}

_each_cached_manifest() {
    find "$CACHE_DIR" -maxdepth 2 -type f -name "manifest.json" 2>/dev/null | sort
}

# _write_plugin_settings <uuid> <name> <dest_dir>
_write_plugin_settings() {
    local uuid="$1"
    local name="$2"
    local dest_dir="$3"
    local manifest="$dest_dir/manifest.json"

    [[ ! -f "$manifest" ]] && return 0

    local reqset pcfg settings
    reqset=$(jq -c '.required_settings // [] | if type == "array" then . else [] end' \
        "$manifest" 2>/dev/null)
    [[ -z "$reqset" || "$reqset" == "null" ]] && reqset="[]"

    # сначала пробуем по uuid, потом по name (обратная совместимость)
    pcfg=$(get_plugin_config_json "$uuid")
    if [[ "$pcfg" == "{}" && "$uuid" != "$name" ]]; then
        pcfg=$(get_plugin_config_json "$name")
    fi
    [[ -z "$pcfg" || "$pcfg" == "null" ]] && pcfg="{}"

    settings=$(jq -nc \
        --argjson cfg "$pcfg" \
        --argjson req "$reqset" \
        'reduce $req[] as $k ({};
            ($cfg | getpath($k | split("."))) as $v
            | if $v != null then .[$k] = $v else . end
        )' 2>/dev/null)
    [[ -z "$settings" || "$settings" == "null" ]] && settings="{}"

    printf '%s\n' "$settings" > "$dest_dir/settings.json"
}

# =====================================================================
#  Кэш
# =====================================================================

cache_plugins() {
    local force="${1:-}"
    mkdir -p "$CACHE_DIR" || return 1

    local fp
    fp=$(_plugins_fingerprint)

    if [[ "$force" != "--force" && -f "$CACHE_STAMP" ]]; then
        local old_fp
        old_fp=$(<"$CACHE_STAMP")
        if [[ "$old_fp" == "$fp" ]]; then
            return 0
        fi
    fi

    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"

    # 1. Обычные папки с manifest.json — кешируем по uuid
    local manifest pname puuid src_dir
    while IFS= read -r -d '' manifest; do
        pname=$(getPluginName "$manifest")
        [[ -z "$pname" || "$pname" == "null" ]] && continue
        puuid=$(getPlugin "$manifest")
        [[ -z "$puuid" ]] && continue

        src_dir=$(dirname "$manifest")
        cp -al "$src_dir" "$CACHE_DIR/$puuid" 2>/dev/null \
            || cp -a "$src_dir" "$CACHE_DIR/$puuid"

        rm -f "$CACHE_DIR/$puuid/.jes_from_bundle"
        touch "$CACHE_DIR/$puuid/.jes_from_folder"
        _write_plugin_settings "$puuid" "$pname" "$CACHE_DIR/$puuid"
    done < <(find "$DIR" -type f -name "manifest.json" -print0)

    # 2. Архивы .jes.pb — тоже по uuid из внутреннего manifest.json
    local archive tmp_dir manifest_path pname2 puuid2 manifest_dir
    while IFS= read -r -d '' archive; do
        pname2="$(basename "$archive" .jes.pb)"

        tmp_dir=$(mktemp -d)
        if ! unzip -q "$archive" -d "$tmp_dir" 2>/dev/null; then
            echo "[cache] failed to unzip: $archive" >&2
            rm -rf "$tmp_dir"
            continue
        fi

        manifest_path=""
        if [[ -f "$tmp_dir/manifest.json" ]]; then
            manifest_path="$tmp_dir/manifest.json"
        elif [[ -f "$tmp_dir/$pname2/manifest.json" ]]; then
            manifest_path="$tmp_dir/$pname2/manifest.json"
        else
            manifest_path=$(find "$tmp_dir" -name manifest.json -type f | head -1)
        fi

        if [[ -z "$manifest_path" ]]; then
            echo "[cache] no manifest.json inside: $archive" >&2
            rm -rf "$tmp_dir"
            continue
        fi

        puuid2=$(getPlugin "$manifest_path")
        pname2=$(getPluginName "$manifest_path")
        manifest_dir=$(dirname "$manifest_path")

        rm -rf "$CACHE_DIR/$puuid2"
        mkdir -p "$CACHE_DIR/$puuid2"
        cp -a "$manifest_dir/." "$CACHE_DIR/$puuid2/"

        rm -f "$CACHE_DIR/$puuid2/.jes_from_folder"
        touch "$CACHE_DIR/$puuid2/.jes_from_bundle"
        _write_plugin_settings "$puuid2" "$pname2" "$CACHE_DIR/$puuid2"

        rm -rf "$tmp_dir"
    done < <(find "$DIR" -maxdepth 1 -type f -name "*.jes.pb" -print0)

    echo "$fp" > "$CACHE_STAMP"
    echo "[cache] rebuilt: $CACHE_DIR" >&2
}

clear_plugin_cache() {
    rm -rf "$CACHE_DIR" "$CACHE_STAMP"
    echo "[cache] cleared" >&2
}

# =====================================================================
#  Листинг
# =====================================================================

_plugin_entry_json() {
    local manifest="$1" host="$2"
    local pname puuid pver active warning compat_out compat_code api_ext
    local pdir cfg_state status uuid_warning raw_uuid

    pname=$(getPluginName "$manifest")
    [[ -z "$pname" || "$pname" == "null" ]] && return 1

    pver=$(jq -r '.api_version' "$manifest" 2>/dev/null)
    [[ -z "$pver" || "$pver" == "null" ]] && return 1

    # --- identity: uuid, fallback на name ---
    raw_uuid=$(jq -r '.uuid // ""' "$manifest" 2>/dev/null)
    puuid=$(getPlugin "$manifest")
    [[ -z "$puuid" ]] && return 1

    uuid_warning=""
    if [[ -z "$raw_uuid" || "$raw_uuid" == "null" ]]; then
        uuid_warning="plugin has no uuid, falling back to name"
    fi

    pdir=$(dirname "$manifest")

    compat_out=$(check_compatibility "$host" "$pver" 2>/dev/null)
    compat_code=$?

    if (( compat_code == 0 )); then
        warning="${compat_out#COMPATIBLE:}"
    else
        warning="${compat_out#INCOMPATIBLE:}"
    fi

    if [[ -n "$uuid_warning" ]]; then
        if [[ -n "$warning" ]]; then
            warning="$uuid_warning; $warning"
        else
            warning="$uuid_warning"
        fi
    fi

    api_ext=$(jq -r '
        ((.api_request // .api_reqest) // [])
        | if type == "array" then . else [] end
        | any(. == "api_extending")
    ' "$manifest" 2>/dev/null)

    if [[ "$api_ext" == "true" ]]; then
        if [[ -n "$warning" ]]; then
            warning="$warning; this plugin extended api"
        else
            warning="this plugin extended api"
        fi
    fi

    # --- Статус: сначала по uuid, потом по name (обратная совместимость) ---
    cfg_state=$(get_plugin_state "$puuid")
    if [[ "$cfg_state" == "unset" && "$puuid" != "$pname" ]]; then
        cfg_state=$(get_plugin_state "$pname")
    fi

    if is_blacklisted "$puuid" || { [[ "$puuid" != "$pname" ]] && is_blacklisted "$pname"; }; then
        status="broken"
        if [[ -n "$warning" ]]; then
            warning="$warning; plugin offed JES, it's moved in black register"
        else
            warning="plugin offed JES, it's moved in black register"
        fi
    elif (( compat_code != 0 )); then
        status="broken"
    elif [[ "$cfg_state" == "unset" ]]; then
        status="unregistered"
    elif [[ -f "$pdir/.jes_from_folder" && "$ENABLE_FOLDERS" != "true" ]]; then
        status="disabled"
        if [[ -n "$warning" ]]; then
            warning="$warning; plugin not in plugin bundle"
        else
            warning="plugin not in plugin bundle"
        fi
    elif [[ "$cfg_state" == "false" ]]; then
        status="disabled"
    else
        status="active"
    fi

    [[ "$status" == "active" ]] && active="true" || active="false"

    local main_src apireq json_files icon reqset pcfg
    main_src=$(jq -r '.main_source // "Main.qml"' "$manifest" 2>/dev/null)
    apireq=$(jq -c '(.api_request // .api_reqest // []) | if type == "array" then . else [] end' "$manifest" 2>/dev/null)
    json_files=$(jq -c '.json_files // {}' "$manifest" 2>/dev/null)
    icon=$(jq -r '.icon // "󰈔"' "$manifest" 2>/dev/null)
    reqset=$(jq -c '.required_settings // [] | if type == "array" then . else [] end' "$manifest" 2>/dev/null)

    pcfg=$(get_plugin_config_json "$puuid")
    if [[ "$pcfg" == "{}" && "$puuid" != "$pname" ]]; then
        pcfg=$(get_plugin_config_json "$pname")
    fi

    [[ -z "$apireq"     || "$apireq"     == "null" ]] && apireq="[]"
    [[ -z "$json_files" || "$json_files" == "null" ]] && json_files="{}"
    [[ -z "$icon"       || "$icon"       == "null" ]] && icon="󰈔"
    [[ -z "$reqset"     || "$reqset"     == "null" ]] && reqset="[]"
    [[ -z "$pcfg"       || "$pcfg"       == "null" ]] && pcfg="{}"

    jq -nc \
        --arg     name  "$pname" \
        --arg     uuid  "$puuid" \
        --arg     ver   "$pver" \
        --argjson active "$active" \
        --arg     stat  "$status" \
        --arg     warn  "$warning" \
        --arg     src   "$CACHE_DIR/$puuid" \
        --arg     main  "$main_src" \
        --argjson apireq "$apireq" \
        --argjson jsonf  "$json_files" \
        --arg     icon  "$icon" \
        --argjson reqset "$reqset" \
        --argjson pcfg   "$pcfg" \
        '{name:$name, uuid:$uuid, api_version:$ver, active:$active, status:$stat,
          warning:$warn, source:$src, main_source:$main, api_request:$apireq,
          json_files:$jsonf, icon:$icon, required_settings:$reqset,
          plugin_config:$pcfg}'
}

list_plugins_info() {
    local mode="${1:-table}"
    local host="${2:-$HOST_VERSION}"
    local first=true entry

    if [[ "$mode" == "json" ]]; then
        echo "["
        while IFS= read -r manifest; do
            entry=$(_plugin_entry_json "$manifest" "$host") || continue
            if $first; then first=false; else echo ","; fi
            printf '  %s\n' "$entry"
        done < <(_each_cached_manifest)
        echo "]"
        return
    fi

    local C_RESET="" C_ACTIVE="" C_DISABLED="" C_UNREG="" C_BROKEN=""
    if [[ -t 1 ]]; then
        C_RESET=$'\033[0m'
        C_ACTIVE=$'\033[32m'
        C_DISABLED=$'\033[33m'
        C_UNREG=$'\033[37m'
        C_BROKEN=$'\033[31m'
    fi

    printf "%-26s %-38s %-14s %s\n" "NAME" "UUID" "STATUS" "WARNING"
    printf "%-26s %-38s %-14s %s\n" "----" "----" "------" "-------"

    local st_color padded pname puuid status warning
    while IFS= read -r manifest; do
        entry=$(_plugin_entry_json "$manifest" "$host") || continue
        pname=$(jq -r '.name'    <<<"$entry")
        puuid=$(jq -r '.uuid'    <<<"$entry")
        status=$(jq -r '.status'  <<<"$entry")
        warning=$(jq -r '.warning' <<<"$entry")
        [[ -z "$warning" ]] && warning="—"

        case "$status" in
            active)       st_color="$C_ACTIVE"   ;;
            disabled)     st_color="$C_DISABLED" ;;
            unregistered) st_color="$C_UNREG"    ;;
            broken)       st_color="$C_BROKEN"   ;;
            *)            st_color=""            ;;
        esac

        padded=$(printf "%-14s" "$status")
        printf "%-26s %-38s %s%s%s %s\n" "$pname" "$puuid" "$st_color" "$padded" "$C_RESET" "$warning"
    done < <(_each_cached_manifest)
}

# =====================================================================
#  Диспетчер
# =====================================================================

case "$CMD" in
    build)
        if [[ "$CMD_EXTRA" != "--force" && -f "$CACHE_STAMP" && -f "$OUTPUT_FILE" ]]; then
            fp_old=$(<"$CACHE_STAMP")
            fp_now=$(_plugins_fingerprint)
            if [[ "$fp_old" == "$fp_now" ]]; then
                exit 0
            fi
        fi

        cache_plugins --force

        {
            echo "["
            first=true
            while IFS= read -r manifest; do
                entry=$(_plugin_entry_json "$manifest" "$HOST_VERSION") || continue

                name=$(jq -r '.name'   <<<"$entry")
                warn=$(jq -r '.warning' <<<"$entry")
                [[ -n "$warn" ]] && echo "[WARN] Plugin $name: $warn" >&2

                if $first; then first=false; else echo ","; fi
                printf '  %s\n' "$entry"
            done < <(_each_cached_manifest)
            echo ""
            echo "]"
        } > "$OUTPUT_FILE.tmp.$$"
        mv "$OUTPUT_FILE.tmp.$$" "$OUTPUT_FILE"

        echo "Готово! Список плагинов записан в $OUTPUT_FILE"

        "$SCRIPT_DIR/plugin_list_launcher.sh"
        "$SCRIPT_DIR/plugin_list_center.sh"
        "$SCRIPT_DIR/plugin_list_osd.sh"
        "$SCRIPT_DIR/plugin_list_Jwindow.sh"
        ;;

    list)       cache_plugins; list_plugins_info table "$HOST_VERSION" ;;
    list-json)  cache_plugins; list_plugins_info json  "$HOST_VERSION" ;;
    cache)      cache_plugins --force ;;
    clear)      clear_plugin_cache ;;

    -h|--help)
        cat <<EOF
Usage: $0 [version] [command] [extra]

Commands:
  build [--force]  (default) — build JSON + refresh cache + run launchers
  list                       — table: name, uuid, status, warning
  list-json                  — same, but JSON
  cache                      — force rebuild cache only
  clear                      — wipe cache

Status:
  active        — registered, active=true, compatible
  disabled      — registered but active=false (or blocked by enableFolders=false)
  unregistered  — not listed in config.toml
  broken        — incompatible, or blacklisted (crashed UI)

Identity:
  uuid is the primary plugin key. If manifest.json has no "uuid" field,
  plugin_list.sh falls back to "name" and notes it in the WARNING column.

Config:
  [settings] enableFolders = true|false   (default: true)
    false — folder-based plugins become disabled
            with warning "plugin not in plugin bundle"
EOF
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        exit 1
        ;;
esac
