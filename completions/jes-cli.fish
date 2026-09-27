# fish completion для jes-cli (динамическая)
# Установка: скопировать в ~/.config/fish/completions/ (или vendor_completions.d)
function __jes_cli_complete
    jes-cli __complete (commandline -opc)[2..-1] ""
end
complete -c jes-cli -f -a '(__jes_cli_complete)'
