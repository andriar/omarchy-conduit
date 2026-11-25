#!/usr/bin/env bash
# Reads the settings the gear panel shows: vpn-load.sh <uuid>
# Labelled lines, so a property a profile does not have (a WireGuard profile has no username)
# cannot shift the others. END marks a complete answer. The password itself never leaves nmcli.
printf 'UUID=%s\n' "$1"
printf 'USER=%s\n' "$(nmcli -g vpn.user-name connection show uuid "$1" 2>/dev/null)"
printf 'NEVER=%s\n' "$(nmcli -g ipv4.never-default connection show uuid "$1" 2>/dev/null)"
printf 'DNS=%s\n' "$(nmcli -g ipv4.ignore-auto-dns connection show uuid "$1" 2>/dev/null)"
if [ -n "$(nmcli -s -g vpn.secrets connection show uuid "$1" 2>/dev/null)" ]; then echo PASS=saved; else echo PASS=none; fi
echo END
