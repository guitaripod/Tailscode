#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

input=$(cat 2>/dev/null || true)
case "$input" in
  *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

problems=$(./scripts/parity.sh --check 2>&1)
if [[ $? -ne 0 ]]; then
  detail=$(printf '%s' "$problems" | head -12 | tr '\n' ' ' | sed 's/"/\\"/g')
  printf '{"decision": "block", "reason": "The parity manifests are invalid — fix them before stopping (scripts/parity.sh): %s"}\n' "$detail"
fi
exit 0
