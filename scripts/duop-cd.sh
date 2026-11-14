#!/usr/bin/env bash
# Shell cd-on-exit wrapper for Duop (`duop --choosedir=FILE`).
# Source this file in ~/.bashrc or ~/.zshrc:
#   source /path/to/duop/scripts/duop-cd.sh
# Then run `dcd` (or alias `duop=dcd`) to cd into the active directory on exit.

dcd() {
    local tmp
    tmp="$(mktemp -t duop-choosedir.XXXXXX)" || return 1
    duop --choosedir="$tmp" "$@"
    local rc=$?
    if [[ -s "$tmp" ]]; then
        local dir
        dir="$(cat "$tmp")"
        if [[ -d "$dir" && "$dir" != "$PWD" ]]; then
            cd -- "$dir" || true
        fi
    fi
    rm -f -- "$tmp"
    return "$rc"
}
