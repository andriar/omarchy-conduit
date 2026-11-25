#!/usr/bin/env bash
# Imports a profile. Environment: VPN_FILE. .conf is taken as WireGuard, anything else (.ovpn) as
# OpenVPN. A new VPN gets a unique name (NAME-2, NAME-3, ...) and starts as split tunnel.
# Output on success: line 1 = uuid, line 2 = final name.
case "$VPN_FILE" in *.conf) t=wireguard;; *) t=openvpn;; esac
out=$(nmcli connection import type "$t" file "$VPN_FILE" 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
uuid=$(printf '%s' "$out" | sed -n 's/.*(\([0-9a-f-]\{36\}\)).*/\1/p' | head -1)
[ -n "$uuid" ] || { echo 'could not find the new connection UUID' >&2; exit 1; }
# Finish the import in one checked step; if any part fails, remove the half-set-up profile so a retry
# does not duplicate it. (Each step ends in "|| exit 1": `set -e` is ignored inside a $( ) that is
# itself part of an `||` list, so it cannot be relied on here.)
res=$(
  base=$(nmcli -g connection.id connection show uuid "$uuid") || exit 1
  name="$base"; n=2
  while [ "$(nmcli -g NAME connection show | grep -cxF -- "$name")" -gt 1 ]; do name="$base-$n"; n=$((n+1)); done
  if [ "$name" != "$base" ]; then nmcli connection modify uuid "$uuid" connection.id "$name" || exit 1; fi
  nmcli connection modify uuid "$uuid" ipv4.never-default yes ipv6.never-default yes || exit 1
  printf '%s\n%s\n' "$uuid" "$name"
) || { nmcli connection delete uuid "$uuid" >/dev/null 2>&1; echo 'could not finish the import; the new profile was removed' >&2; exit 1; }
printf '%s\n' "$res"
