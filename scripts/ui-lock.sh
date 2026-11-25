#!/usr/bin/env bash
# Regenerate ui.lock: the version and SHA-256 of every shared Conduit*.qml component.
# Run it after you change a component:  scripts/ui-lock.sh <new-version>
# Downstream Conduit plugins copy these files with scripts/sync-ui.sh and verify them against ui.lock.
set -euo pipefail
cd "$(dirname "$0")/.."

current=$(awk '/^version /{print $2}' ui.lock 2>/dev/null || true)
version="${1:-${current:-1}}"
[[ $version =~ ^[0-9]+$ ]] || { echo "ui-lock: version must be a whole number" >&2; exit 1; }

{
  echo "# Conduit UI kit lock. Source of truth: andriar/omarchy-conduit-vpn"
  echo "# Regenerate with scripts/ui-lock.sh <version> after changing a Conduit*.qml component."
  echo "version $version"
  sha256sum Conduit*.qml
} > ui.lock
echo "ui-lock: version $version, $(grep -c -E '^[0-9a-f]{64}  ' ui.lock) components"
