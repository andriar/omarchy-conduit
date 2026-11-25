#!/usr/bin/env bash
# Saves the auto-connect list (environment AUTO_LIST, one uuid per line). The file is written to a
# temporary name and renamed, so a crash or a second writer never leaves a half-written list.
d="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-conduit"
mkdir -p "$d" || exit 1
tmp=$(mktemp "$d/autoconnect.XXXXXX") || exit 1
if ! { printf '%s\n' "$AUTO_LIST" > "$tmp" && mv -f "$tmp" "$d/autoconnect"; }; then rm -f "$tmp"; exit 1; fi
