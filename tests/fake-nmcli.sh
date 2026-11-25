#!/usr/bin/env bash
# A tiny stand-in for nmcli, for tests/scripts.test.sh. State lives in $FAKE_DIR:
#   conns   one "uuid|name|type" per line         active  one "uuid|state|type" per line
#   props   "uuid|property|value" lines            log     every call, one line, args joined with ␟
#   secrets uuid -> password (written by `edit`)   fail    "<word>" makes any call containing it exit 4
# Only the calls the plugin scripts make are implemented.
d=${FAKE_DIR:?}
printf '%s\n' "$(IFS=$'\x1f'; echo "$*")" >> "$d/log"
args=" $* "
if [ -f "$d/fail" ] && [[ $args == *" $(cat "$d/fail") "* ]]; then echo "Error: simulated failure" >&2; exit 4; fi
prop() { awk -F'|' -v u="$1" -v p="$2" '$1==u && $2==p {print $3; f=1} END{exit !f}' "$d/props"; }
setprop() { grep -v -F "$1|$2|" "$d/props" > "$d/props.new"; echo "$1|$2|$3" >> "$d/props.new"; mv "$d/props.new" "$d/props"; }
case "$*" in
  "-t -f UUID,NAME,TYPE connection show") awk -F'|' '{n=$2; gsub(/:/,"\\:",n); print $1":"n":"$3}' "$d/conns" ;;
  "-t -f UUID,STATE connection show --active") awk -F'|' '{print $1":"$2}' "$d/active" ;;
  "-t -f TYPE,STATE connection show --active") awk -F'|' '{print $3":"$2}' "$d/active" ;;
  "-t -f UUID,TYPE connection show --active") awk -F'|' '{print $1":"$3}' "$d/active" ;;
  "-g NAME connection show") cut -d'|' -f2 "$d/conns" ;;
  "-t -f IP4.ADDRESS connection show uuid "*) echo "IP4.ADDRESS[1]:$(prop "$7" ip4 || true)" ;;
  "-g connection.timestamp connection show uuid "*) prop "$6" ts ;;
  "-g "*" connection show uuid "*) prop "$6" "$2" || true ;;
  "-s -g vpn.secrets connection show uuid "*) [ -f "$d/secret.$7" ] && echo "password = $(cat "$d/secret.$7")" || true ;;
  "connection modify uuid "*)
    u=$4; shift 4
    while [ $# -gt 0 ]; do
      case "$1" in
        +vpn.data) setprop "$u" vpn.data "$2"; shift 2 ;;
        *) setprop "$u" "$1" "$2"; shift 2 ;;
      esac
    done ;;
  "connection edit uuid "*) pw=$(sed -n 's/^set vpn.secrets password=//p'); printf '%s' "$pw" > "$d/secret.$4" ;;
  "connection delete uuid "*) grep -v "^$4|" "$d/conns" > "$d/conns.new"; mv "$d/conns.new" "$d/conns" ;;
  "connection import type "*)
    t=$4; f=$6; base=$(basename "$f"); base=${base%.*}
    u=$(printf '%s' "$base" | md5sum | cut -c1-8)-0000-0000-0000-000000000000
    u=${u:0:36}; u=$(printf '%s%s' "${u:0:8}" "-1111-2222-3333-444444444444")
    echo "$u|$base|$([ "$t" = wireguard ] && echo wireguard || echo vpn)" >> "$d/conns"
    setprop "$u" connection.id "$base"
    echo "Connection '$base' ($u) successfully added." ;;
  "connection up uuid "*) echo "Connection successfully activated" ;;
  "connection down uuid "*) echo "Connection deactivated" ;;
  *) echo "fake-nmcli: unhandled: $*" >&2; exit 99 ;;
esac
