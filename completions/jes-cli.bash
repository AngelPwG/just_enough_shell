# bash completion для jes-cli (динамическая)
# Установка: скопировать в /usr/share/bash-completion/completions/jes-cli
_jes_cli_completion() {
    local IFS=$'\n'
    COMPREPLY=( $(jes-cli __complete "${COMP_WORDS[@]:1}") )
}
complete -F _jes_cli_completion jes-cli
