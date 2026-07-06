# Tailscode

A native **UIKit** iOS client for remote coding agents — **opencode** and **Claude Code (via agentapi)** — reached over **Tailscale**. Built entirely on top of [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit); the app is a thin, polished shell over the Kit's unified conversation engine.

Programmatic UIKit (no storyboards, no SwiftUI), MVVM + a coordinator, Swift 6 strict concurrency, iOS 18+.

## Features

- **Connect over Tailscale** — enter a host + password; the connection is probed and auto-detected (opencode vs agentapi), then stored in the Keychain via `ConnectionProfileStore`.
- **Sessions** — list, create, delete (opencode), pull-to-refresh.
- **Streaming chat** — reasoning, streamed assistant text, and expandable **tool-call cards**, folded from the backend's SSE by the Kit's `MessageReducer`.
- **Permissions** — opencode permission prompts surface as an Allow-once / Always / Deny sheet.
- **Attachments** — send a photo with a prompt (opencode).
- **Model picker**, **auto-reconnect** with a connection banner, **Settings** with multiple connection profiles and a health check.
- Dark mode, Dynamic Type, haptics, and a file-based `AppLogger` (`Library/Logs/tailscode.log`) from day one.

## Build & run (macOS, Xcode 26)

The project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Tailscode.xcodeproj      # or: xcodebuild -scheme Tailscode -destination 'generic/platform=iOS Simulator' build
```

Two convenience scripts drive a remote Mac over SSH/Tailscale (author on Linux, build on macOS):

- `scripts/build-mac.sh` — rsync + `xcodegen` + `xcodebuild` (simulator).
- `scripts/run-mac.sh` — build, install on a simulator, capture screenshots. Supports a `--demo` launch (scripted conversation via the Kit's `MockBackend`, no server) and a DEBUG env auto-connect (`TAILSCODE_HOST` / `TAILSCODE_PASSWORD`).

## Structure

```
Tailscode/
  App/           AppDelegate, SceneDelegate, AppCoordinator (routing: onboarding ↔ main)
  DesignSystem/  Theme (colors, spacing, typography, haptics)
  Logging/       AppLogger + LogFileWriter (OSLog + rotated file)
  Connection/    ConnectionController, AppCache, UnavailableBackend
  Onboarding/    OnboardingViewController (+ ConnectionProbe)
  Sessions/      SessionListViewController + ViewModel
  Chat/          ChatViewController + ViewModel, cells, ComposerView
  Settings/      SettingsViewController
```
