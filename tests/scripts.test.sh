#!/usr/bin/env bash
# Runs scripts/vpn-*.sh against tests/fake-nmcli.sh (no NetworkManager needed).
# Run with: tests/scripts.test.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1${2:+  ($2)}"; }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3" "got '$1' want '$2'"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir "$W/bin"; ln -s "$ROOT/tests/fake-nmcli.sh" "$W/bin/nmcli"
export PATH="$W/bin:$PATH" FAKE_DIR="$W/state" XDG_RUNTIME_DIR="$W"
U1=11111111-1111-1111-1111-111111111111; U2=22222222-2222-2222-2222-222222222222; U3=33333333-3333-3333-3333-333333333333
reset() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  printf '%s\n' "$U1|Work|vpn" "$U2|home wg|wireguard" "$U3|Office: HQ|vpn" "44444444-4444-4444-4444-444444444444|Wired|ethernet" > "$FAKE_DIR/conns"
  printf '%s\n' "$U1|activated|vpn" "44444444-4444-4444-4444-444444444444|activated|ethernet" > "$FAKE_DIR/active"
  printf '%s\n' "$U1|vpn.user-name|alice" "$U1|connection.type|vpn" "$U1|ip4|10.8.0.2/24" "$U1|ts|1700000000" \
    "$U1|ipv4.never-default|yes" "$U1|ipv4.ignore-auto-dns|no" "$U2|connection.type|wireguard" > "$FAKE_DIR/props"
  : > "$FAKE_DIR/log"
}
run() { bash "$ROOT/scripts/$1" "${@:2}"; }

# ---- vpn-list.sh ----
reset; out=$(run vpn-list.sh)
grep -q "^$U1:Work:vpn$" <<<"$out" && ok "list: VPN rows, no ethernet" || bad "list rows" "$out"
grep -q "Wired" <<<"$out" && bad "list shows non-VPN" || ok "list hides non-VPN"
grep -q "^Office\\\\: HQ\|:Office\\\\: HQ:vpn$" <<<"$out" && ok "list: colon in name stays escaped" || bad "list escaped colon" "$out"
grep -q "^NET:1$" <<<"$out" && ok "list: NET counts non-VPN active" || bad "list NET" "$out"
grep -q "^INFO:$U1:10.8.0.2:1700000000$" <<<"$out" && ok "list: INFO ip and timestamp" || bad "list INFO" "$out"
reset; : > "$FAKE_DIR/active"; out=$(run vpn-list.sh)
grep -q "^NET:0$" <<<"$out" && ! grep -q "^INFO" <<<"$out" && ok "list: nothing active" || bad "list idle" "$out"

# ---- vpn-load.sh ----
reset; out=$(run vpn-load.sh "$U1")
eq "$out" "UUID=$U1
USER=alice
NEVER=yes
DNS=no
PASS=none
END" "load: labelled lines"
echo secret > "$FAKE_DIR/secret.$U1"; out=$(run vpn-load.sh "$U1")
grep -q "^PASS=saved$" <<<"$out" && ok "load: saved password flagged" || bad "load saved" "$out"
grep -q "secret" <<<"$out" && bad "load leaks the password" || ok "load never prints the password"
out=$(run vpn-load.sh "$U2")
grep -q "^USER=$" <<<"$out" && grep -q "^END$" <<<"$out" && ok "load: WireGuard has empty USER, still ends" || bad "load wg" "$out"

# ---- vpn-save.sh ----
reset; VPN_UUID=$U1 VPN_USER_CHANGED=1 VPN_USER=bob run vpn-save.sh; rc=$?
eq "$rc" 0 "save: user exit 0"
grep -q "^$U1|vpn.user-name|bob$" "$FAKE_DIR/props" && ok "save: username written" || bad "save user"
reset; VPN_UUID=$U2 VPN_USER_CHANGED=1 VPN_USER=bob run vpn-save.sh
grep -q "^$U2|vpn.user-name" "$FAKE_DIR/props" && bad "save: wrote username on a WireGuard profile" || ok "save: username skipped for non-vpn type"
reset; VPN_UUID=$U1 run vpn-save.sh; eq "$(grep -c modify "$FAKE_DIR/log")" 0 "save: nothing changed, nothing modified"
reset; VPN_UUID=$U1 VPN_SPLIT_CHANGED=1 VPN_SPLIT=no VPN_DNS_CHANGED=1 VPN_IGNDNS=yes VPN_NEWNAME="New name" run vpn-save.sh
grep -q "^$U1|ipv4.never-default|no$" "$FAKE_DIR/props" && grep -q "^$U1|ipv6.never-default|no$" "$FAKE_DIR/props" \
  && grep -q "^$U1|ipv4.ignore-auto-dns|yes$" "$FAKE_DIR/props" && grep -q "^$U1|connection.id|New name$" "$FAKE_DIR/props" \
  && ok "save: split, dns and name written" || bad "save split/dns/name" "$(cat "$FAKE_DIR/props")"
reset; VPN_UUID=$U1 VPN_PASS='p@ss word$1' run vpn-save.sh; rc=$?
eq "$rc" 0 "save: password exit 0"
eq "$(cat "$FAKE_DIR/secret.$U1")" 'p@ss word$1' "save: password stored verbatim"
grep -q "^$U1|vpn.data|password-flags=0$" "$FAKE_DIR/props" && ok "save: password-flags=0 forced" || bad "save flags"
grep -q 'p@ss' "$FAKE_DIR/log" && bad "save: password appeared in nmcli argv" || ok "save: password never in argv"
reset; echo "modify" > "$FAKE_DIR/fail"; VPN_UUID=$U1 VPN_USER_CHANGED=1 VPN_USER=x run vpn-save.sh 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "save: nmcli failure fails the script" || bad "save failure ignored"

# ---- vpn-action.sh ----
reset; VPN_UUID=$U1 VPN_ACT=up run vpn-action.sh >/dev/null; eq "$?" 0 "action up: exit 0"
reset; VPN_UUID=$U1 VPN_ACT=reconnect run vpn-action.sh >/dev/null
eq "$(grep -c '^connection.down\|^connection␟down' "$FAKE_DIR/log")" 1 "action reconnect: runs down first"
grep -q "up" <(tail -1 "$FAKE_DIR/log") && ok "action reconnect: then up" || bad "reconnect up"
reset; VPN_UUID=$U1 VPN_ACT=up VPN_SECRET='123456' run vpn-action.sh >/dev/null
grep -q "passwd-file" "$FAKE_DIR/log" && ok "action: one-time secret passed via passwd-file" || bad "action passwd-file"
grep -q '123456' "$FAKE_DIR/log" && bad "action: secret in argv" || ok "action: secret not in argv"
eq "$(ls "$W"/vpn.* 2>/dev/null | wc -l)" 0 "action: temp file removed"
reset; echo "up" > "$FAKE_DIR/fail"; out=$(VPN_UUID=$U1 VPN_ACT=up run vpn-action.sh 2>/dev/null); rc=$?
eq "$rc" 4 "action failure: nmcli exit code kept"
grep -q "simulated failure" <<<"$out" && ok "action failure: message passed on" || bad "action failure message" "$out"
reset; echo "up" > "$FAKE_DIR/fail"; VPN_UUID=$U1 VPN_ACT=up VPN_SECRET=zzz run vpn-action.sh >/dev/null 2>&1
eq "$(ls "$W"/vpn.* 2>/dev/null | wc -l)" 0 "action failure: temp file still removed"

# ---- vpn-import.sh ----
reset; : > "$W/work.ovpn"; out=$(VPN_FILE="$W/work.ovpn" run vpn-import.sh); rc=$?
eq "$rc" 0 "import: exit 0"
eq "$(sed -n 2p <<<"$out")" work "import: name from file"
nu=$(sed -n 1p <<<"$out")
grep -q "^$nu|work|vpn$" "$FAKE_DIR/conns" && ok "import: .ovpn is OpenVPN" || bad "import type" "$(cat "$FAKE_DIR/conns")"
grep -q "^$nu|ipv4.never-default|yes$" "$FAKE_DIR/props" && ok "import: starts as split tunnel" || bad "import split"
: > "$W/home wg.conf"; out=$(VPN_FILE="$W/home wg.conf" run vpn-import.sh)
nu=$(sed -n 1p <<<"$out"); eq "$(sed -n 2p <<<"$out")" "home wg-2" "import: duplicate name gets -2"
grep -q "^$nu|home wg|wireguard$" "$FAKE_DIR/conns" && ok "import: .conf is WireGuard" || bad "import wg type"
reset; echo "modify" > "$FAKE_DIR/fail"; : > "$W/x.ovpn"; out=$(VPN_FILE="$W/x.ovpn" run vpn-import.sh 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "import rollback: fails" || bad "import rollback rc"
grep -q "|x|" "$FAKE_DIR/conns" && bad "import rollback: half-made profile left behind" || ok "import rollback: profile removed"
reset; echo "import" > "$FAKE_DIR/fail"; out=$(VPN_FILE="$W/x.ovpn" run vpn-import.sh 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q "simulated failure" <<<"$out" && ok "import: nmcli error shown" || bad "import error" "$out"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
