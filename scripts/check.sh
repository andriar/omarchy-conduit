#!/usr/bin/env bash
# Sanity checks, run locally and in CI:  scripts/check.sh
# - manifest.json is valid and has what Omarchy requires
# - every file the manifest points at exists
# - Model.js passes its unit tests (when node is installed)
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

# The shared Conduit* components next to the panel must be present (QML siblings are auto-imported).
for f in Panel.qml ConduitButton.qml ConduitSwitch.qml ConduitToggleRow.qml; do
  [[ -f $f ]] || fail "missing $f"
done

# The shared UI kit must match ui.lock (edit a component -> scripts/ui-lock.sh <version>).
[[ -f ui.lock ]] || fail "ui.lock is missing"
grep -E '^[0-9a-f]{64}  ' ui.lock | sha256sum -c --quiet 2>/dev/null || fail "a Conduit*.qml component does not match ui.lock (run scripts/ui-lock.sh <version>, or scripts/sync-ui.sh in a downstream plugin)"
for f in Conduit*.qml; do
  grep -q -E "^[0-9a-f]{64}  $f$" ui.lock || fail "$f is not listed in ui.lock"
done

# The module id used in code must match the manifest id.
grep -q "moduleName: \"$id\"" Panel.qml || fail "Panel.qml moduleName does not match manifest id '$id'"

# Translations: valid JSON, no unknown keys, and every key used in code exists in en.json.
for f in i18n/*.json; do jq -e 'type == "object"' "$f" >/dev/null || fail "$f is not a JSON object"; done
[[ -f i18n/en.json ]] || fail "i18n/en.json (the reference catalog) is missing"
for f in i18n/*.json; do
  extra=$(jq -r --slurpfile en i18n/en.json 'keys[] | select(. as $k | ($en[0] | has($k)) | not)' "$f")
  [[ -z $extra ]] || fail "$f has keys that are not in en.json: $extra"
done
while IFS= read -r key; do
  jq -e --arg k "$key" 'has($k)' i18n/en.json >/dev/null || fail "Panel.qml uses strings.t(\"$key\") but en.json does not define it"
done < <(grep -o 'strings\.t("[^"]*")' *.qml | sed -E 's/.*strings\.t\("([^"]*)"\)/\1/' | sort -u)

# Unit tests for Model.js (parsing, auto-connect decisions, notification escaping).
if command -v node >/dev/null; then
  node tests/model.test.js >/dev/null || fail "tests/model.test.js failed (run it to see why)"
else
  echo "check: node not found, skipping tests/model.test.js"
fi

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
