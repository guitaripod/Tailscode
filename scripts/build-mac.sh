#!/usr/bin/env bash
# Sync CodingAgentKit + Tailscode to the Mac and build for the iOS Simulator over Tailscale.
set -euo pipefail

RSYNC_EXCLUDES=(--exclude '.git' --exclude '.build' --exclude 'build' --exclude 'DerivedData' --exclude '*.xcodeproj')

rsync -az --delete "${RSYNC_EXCLUDES[@]}" ~/Dev/swift/CodingAgentKit/ macbook:Dev/swift/CodingAgentKit/
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ~/Dev/ios/Tailscode/ macbook:Dev/ios/Tailscode/

ssh macbook 'bash -l -c "cd ~/Dev/ios/Tailscode && xcodegen generate >/dev/null && xcodebuild -project Tailscode.xcodeproj -scheme Tailscode -destination \"generic/platform=iOS Simulator\" -configuration Debug build 2>&1 | (grep -E \"error:|BUILD (SUCCEEDED|FAILED)\" || true) | tail -60"'
