#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

hits=$(grep -n -E \
  -e 'Latest releases?:' \
  -e '\*\*(iPhone|iPad|macOS|Mac|Linux) [0-9]+\.[0-9]+' \
  -e '`v[0-9]+\.[0-9]+' \
  -e 'tailscode-[0-9]+\.[0-9]+' \
  -e 'pinned at [0-9]' \
  README.md)
if [[ -n "$hits" ]]; then
  echo "README.md names a release version, which goes stale at the next release; leave versions to the App Store, AUR and GitHub releases:" >&2
  echo "$hits" >&2
  exit 1
fi
exit 0
