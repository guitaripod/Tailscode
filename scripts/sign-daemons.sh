#!/usr/bin/env bash
set -euo pipefail

BINARIES=(
  "com.guitaripod.delegate|$HOME/.cargo/bin/delegate"
  "com.guitaripod.previewd|$HOME/Library/Application Support/previewd/bin/previewd"
  "com.guitaripod.claude-bridge|$HOME/.claude-bridge/bin/claude-bridge"
)

resign() {
  local identifier="$1" path="$2"
  [ -f "$path" ] || { echo "skip   $path (not installed)"; return 0; }
  codesign --force --sign - --identifier "$identifier" \
    --requirements "=designated => identifier \"$identifier\"" "$path"
  echo "signed $path as $identifier"
}

firewall_line() {
  local lines=""
  for entry in "${BINARIES[@]}"; do
    local path="${entry#*|}"
    [ -f "$path" ] || continue
    lines+="sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \"$path\" --unblockapp \"$path\"; "
  done
  printf '%s\n' "$lines"
}

for entry in "${BINARIES[@]}"; do
  resign "${entry%%|*}" "${entry#*|}"
done

echo
echo "Run once to pre-approve them with the firewall (needs your password):"
firewall_line
