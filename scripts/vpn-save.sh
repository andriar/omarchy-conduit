#!/usr/bin/env bash
# Saves the gear panel. Environment: VPN_UUID, and only for what changed:
# VPN_USER_CHANGED + VPN_USER, VPN_SPLIT_CHANGED + VPN_SPLIT, VPN_DNS_CHANGED + VPN_IGNDNS,
# VPN_NEWNAME, VPN_PASS.
set -e
# Only what changed is written, and only what the profile has (a WireGuard profile has no username).
if [ -n "$VPN_USER_CHANGED" ] && [ "$(nmcli -g connection.type connection show uuid "$VPN_UUID" 2>/dev/null)" = vpn ]; then
  nmcli connection modify uuid "$VPN_UUID" vpn.user-name "$VPN_USER"
fi
if [ -n "$VPN_SPLIT_CHANGED" ]; then nmcli connection modify uuid "$VPN_UUID" ipv4.never-default "$VPN_SPLIT" ipv6.never-default "$VPN_SPLIT"; fi
if [ -n "$VPN_DNS_CHANGED" ]; then nmcli connection modify uuid "$VPN_UUID" ipv4.ignore-auto-dns "$VPN_IGNDNS" ipv6.ignore-auto-dns "$VPN_IGNDNS"; fi
if [ -n "$VPN_NEWNAME" ]; then nmcli connection modify uuid "$VPN_UUID" connection.id "$VPN_NEWNAME"; fi
if [ -n "$VPN_PASS" ]; then
  nmcli connection modify uuid "$VPN_UUID" +vpn.data password-flags=0
  # The password goes in through the editor's standard input (a shell builtin feeds it), so it is
  # never on a command line where other users could read it. Then check that it was stored.
  printf 'set vpn.secrets password=%s\nsave\nquit\n' "$VPN_PASS" | nmcli connection edit uuid "$VPN_UUID" >/dev/null
  [ -n "$(nmcli -s -g vpn.secrets connection show uuid "$VPN_UUID" 2>/dev/null)" ]
fi
