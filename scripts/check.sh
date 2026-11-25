#!/usr/bin/env bash
# Sanity checks, run locally and in CI:  scripts/check.sh
# - manifest.json is valid and has what Omarchy requires
# - every file the manifest points at exists
# - nothing that looks like a VPN profile or a credential is committed
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "check: $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required"

jq -e . manifest.json >/dev/null || fail "manifest.json is not valid JSON"
jq -e '.schemaVersion == 1' manifest.json >/dev/null || fail "schemaVersion must be 1"
for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' manifest.json >/dev/null || fail "manifest.json is missing '$field'"
done

id=$(jq -r .id manifest.json)
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid plugin id '$id'"
[[ $id != omarchy.* ]] || fail "plugin id must not use the reserved omarchy.* namespace"

while IFS= read -r entry; do
  [[ -f $entry ]] || fail "manifest entry point not found: $entry"
done < <(jq -r '.entryPoints | to_entries[] | .value' manifest.json)

# Every Vpn*.qml component next to the panel must be tracked (QML siblings are auto-imported).
for f in Panel.qml VpnButton.qml VpnSwitch.qml VpnToggleRow.qml; do
  [[ -f $f ]] || fail "missing $f"
done

# The module id used in code must match the manifest id.
grep -q "moduleName: \"$id\"" Panel.qml || fail "Panel.qml moduleName does not match manifest id '$id'"

# Secret / profile scan (tracked and untracked-but-not-ignored files).
pattern='BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY|BEGIN CERTIFICATE|<tls-(auth|crypt)|<ca>|auth-user-pass +[^ ]'
if git ls-files --cached --others --exclude-standard -z | xargs -0 grep -I -n -E -e "$pattern" -- 2>/dev/null \
    | grep -v -E '^(scripts/check\.sh|README\.md):'; then
  fail "found text that looks like a VPN profile or a private key"
fi
if git ls-files --cached --others --exclude-standard | grep -E '\.(ovpn|pem|key|crt|p12)$'; then
  fail "a VPN profile or key file is tracked"
fi

echo "check: ok ($id)"
