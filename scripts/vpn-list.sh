#!/usr/bin/env bash
# Lists VPN / WireGuard connections and which are active. Parsed by Model.js parse().
#   UUID:NAME:TYPE ...
#   ---
#   UUID:STATE ... (active connections)
#   NET:<n>               how many non-VPN connections are up (is there a network at all)
#   INFO:<uuid>:<ip>:<ts> address and activation time of each connected VPN
nmcli -t -f UUID,NAME,TYPE connection show | grep -E ':(vpn|wireguard)$'
echo '---'
nmcli -t -f UUID,STATE connection show --active
echo "NET:$(nmcli -t -f TYPE,STATE connection show --active | grep -v -E '^(vpn|wireguard|loopback|bridge|tun|dummy)' | grep -c ':activated')"
for u in $(nmcli -t -f UUID,TYPE connection show --active | grep -E ':(vpn|wireguard)$' | cut -d: -f1); do
  ip=$(nmcli -t -f IP4.ADDRESS connection show uuid "$u" 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1)
  ts=$(nmcli -g connection.timestamp connection show uuid "$u" 2>/dev/null)
  echo "INFO:$u:$ip:$ts"
done
exit 0
