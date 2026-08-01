#!/usr/bin/env bash
# Sync CodingAgentKit + Tailscode to the Mac and build for the iOS Simulator over Tailscale.
# Run on the Mac itself, the sync is skipped: rsyncing a tree onto itself is not a no-op.
set -euo pipefail

BUILD='cd ~/Dev/iOS/Tailscode && xcodegen generate >/dev/null && xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -destination "generic/platform=iOS Simulator" -configuration Debug build > /tmp/tailscode-build.log 2>&1; st=$?; grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/tailscode-build.log | tail -60; exit $st'

if [[ "$(hostname -s)" == "macbook" ]]; then
    bash -l -c "$BUILD"
    exit $?
fi

RSYNC_EXCLUDES=(--exclude '.git' --exclude '.build' --exclude 'build' --exclude 'build-*' --exclude 'DerivedData' --exclude '*.xcodeproj')

rsync -az "${RSYNC_EXCLUDES[@]}" ~/Dev/swift/CodingAgentKit/ macbook:Dev/swift/CodingAgentKit/
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ~/Dev/iOS/Tailscode/ macbook:Dev/iOS/Tailscode/

ssh macbook "bash -l -c $(printf '%q' "$BUILD")"
