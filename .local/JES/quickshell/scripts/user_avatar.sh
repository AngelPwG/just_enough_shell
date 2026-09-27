#!/usr/bin/env bash
# Возвращает путь к аватарке юзера или exit 1 (тогда QML рисует заглушку).
user="${1:-$USER}"
home="${HOME:-/home/$user}"

for p in \
    "/var/lib/AccountsService/icons/$user" \
    "/var/lib/AccountsService/icons/$user.png" \
    "$home/.face" \
    "$home/.face.icon"
do
    if [ -f "$p" ] && [ -r "$p" ]; then
        printf '%s\n' "$p"
        exit 0
    fi
done
exit 1
