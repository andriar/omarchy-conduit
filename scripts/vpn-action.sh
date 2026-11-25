#!/usr/bin/env bash
# Connect / disconnect. Environment: VPN_UUID, VPN_ACT (up|down|reconnect), VPN_SECRET (optional one-time secret).
# The log is read only from the moment this action started, so an older failed login (of this or
# another VPN) is not blamed on it. On failure, also look for the server rejecting the login: nmcli itself only says
# "activation failed", the reason is in the NetworkManager log.
started=$(date +%s)
if [ "$VPN_ACT" = reconnect ]; then nmcli connection down uuid "$VPN_UUID" >/dev/null 2>&1; VPN_ACT=up; fi
# A one-time secret goes through a private temp file, never on a command line.
extra=''; f=''
cleanup() { [ -n "$f" ] && rm -f "$f"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$VPN_SECRET" ]; then
  f=$(mktemp -p "${XDG_RUNTIME_DIR:-/tmp}" vpn.XXXXXX); chmod 600 "$f"
  printf 'vpn.secrets.password:%s\n' "$VPN_SECRET" > "$f"; unset VPN_SECRET; extra="passwd-file $f"
fi
# shellcheck disable=SC2086  # $extra is "passwd-file <path>" or empty, two words on purpose
out=$(nmcli connection "$VPN_ACT" uuid "$VPN_UUID" $extra 2>&1); rc=$?
cleanup; f=''
if [ $rc -ne 0 ]; then
  if journalctl -u NetworkManager --since "@$started" --no-pager 2>/dev/null | grep -q AUTH_FAILED; then echo AUTH_FAILED; else printf '%s\n' "$out"; fi
fi
exit $rc
