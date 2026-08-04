# Tailscode

**Drive your coding agents from every seat.** Tailscode is three native clients for remote coding agents — [opencode](https://opencode.ai) and **Claude Code** (via [claude-bridge](https://github.com/guitaripod/claude-bridge)) — reached over [Tailscale](https://tailscale.com): **iOS** (UIKit), **Linux** (GTK4), and **macOS** (AppKit, Liquid Glass). One conversation engine, one shared core (`TailscodeCore`), feature parity enforced by a capability registry.

<p align="center">
  <a href="https://apps.apple.com/app/tailscode/id6791660932"><b>Download on the App Store</b></a> · free, with a one-time Pro unlock · <a href="LICENSE">GPL-3.0</a>
</p>

Built on [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit), a GPL-3.0 Swift package that unifies both backends behind one conversation engine. The clients are polished shells; the engine is reusable.

## Why

Coding agents run long turns on machines that aren't in front of you. The phone is the remote control — full streaming transcripts, tool-call visibility, permission approvals, and Live Activities — so "prompt and bounce" actually works. The desktops are the multi-pane workspace: tiled chats, a terminal and file tree beside them, optional browser and video slots, vim in the composer.

<p align="center">
  <img src="docs/screenshot-streaming.png" width="240" alt="A live turn: elapsed status, collapsed thought group, streamed code, running command" />
  &nbsp;
  <img src="docs/screenshot-home.png" width="240" alt="Home: what is live now, projects, recent chats, a docked composer" />
  &nbsp;
  <img src="docs/screenshot-code.png" width="240" alt="Finished turn with syntax-highlighted code block" />
</p>

## Features

**Home**
- A board, not a server list: what's **live now**, the projects you work in, recent chats with unread badges, and your plan gauges — refreshed while you look at it.
- A **docked composer** starts a chat before one exists: pick project, server, model and effort, type, send.

**Chat**
- Streaming transcripts with collapsible **thought + tool activity groups**, syntax-highlighted code blocks (horizontally scrollable, byte-exact copy), markdown rendering, and per-turn timestamps.
- **Optimistic sends** — your prompt echoes instantly, the thinking indicator engages in the same frame, and failures hand your text back instead of eating it.
- **Steering** — type while the agent runs to queue a follow-up; edit or cancel queued messages; stop aborts server-side.
- **Inline permission approvals** — Allow once / Always / Deny cards in the transcript, with haptic + notification alerts.
- **Answerable questions** — an agent's `AskUserQuestion` becomes a real form docked at the end of the transcript (single- and multi-select, "Other…", skip).
- **Subagents render in place** — a spawned agent expands as a card at its own tool call, with its transcript and what it reported back; a wide fan-out collapses behind one row.
- **Compaction is a seam you can read** — `/compact` opens a preflight (it is irreversible and takes minutes) and lands as a divider showing what was traded for what, with the full summary behind it in a reader.
- **Prompt enhance** — hold Send to rewrite a rough prompt on-device with Apple's Foundation Models (iOS 26); nothing leaves the phone.
- Slash-command palette backed by the **server's own commands** (`/goal`, `/compact`, `/usage`, `/model`, `/fork`, project and plugin commands), message context menus (copy / quote / share), jump-to-message, regenerate, per-session drafts.
- **Model picker** with provider grouping, search and recents; per-message model/effort overrides via long-press send; Claude reasoning-effort control.
- **Fork** a conversation to explore an alternate direction. **Save** one to keep a full local snapshot that still opens when the server is gone.
- Session usage meter (tokens + cost), attachments (photos, files, large-paste-as-file) that render inline.

**Live Activities & notifications**
- Per-session Lock Screen + Dynamic Island activities with live phase (thinking / running tool / writing / awaiting approval), elapsed timer and tool counts.
- claude-bridge pushes updates over APNs, so the Lock Screen keeps ticking while the app is suspended; approval requests alert, finished turns linger with the outcome.
- **Tap to deep-link into that exact chat.** Every notification type is individually switchable.

**Sessions & servers**
- Unified session list across **multiple servers**, grouped by machine, with live status pills, search (titles, projects, servers), swipe actions and context menus.
- Server-side **file browser** for picking a project directory (favorites + recents).
- **Tailnet discovery** — paste a Tailscale API token and Tailscode scans your devices for running agent servers; servers stay editable afterwards.
- Connection health checks, auto-reconnect with resync-on-foreground, offline banners, and a Settings screen that explains what is broken rather than just failing.

**Widgets**
- Home Screen widgets fetch your Claude/Grok/opencode quotas themselves — an app group + keychain access group let the timeline refresh without opening the app.

**Fit & finish**
- Liquid Glass (iOS 26) composer, FAB and banners with material fallbacks; dark mode; Dynamic Type; haptics everywhere (toggleable).
- Localized into **ten languages** (English, German, Spanish, French, Italian, Japanese, Korean, Brazilian Portuguese, Simplified and Traditional Chinese).
- File-based diagnostics logger with an in-app colorized viewer and a shareable report.

## Clients

| Client | Toolkit | Where it shines |
|---|---|---|
| **iOS** (`Tailscode/`) | UIKit, iOS 18+ | Pocket remote: Live Activities, haptics, widgets, on-device prompt enhance |
| **Linux** (`TailscodeLinux/`) | GTK4 + libadwaita | Tiling panes, named themes, terminal, file tree, browser/video slots |
| **macOS** (`TailscodeMac/`) | AppKit, macOS 26+ Liquid Glass | Same tiling workspace on the Mac; system materials for chrome |

Shared toolkit-free logic lives in `TailscodeCore/`. `scripts/parity.sh` prints the capability matrix and greps every claimed anchor.

## Requirements

- **iOS** 18+ (Liquid Glass and prompt enhance on iOS 26+).
- **macOS** 26+ for TailscodeMac.
- **Linux** with GTK4/libadwaita (optional VTE, mpv, WebKitGTK for terminal/video/browser panes).
- A machine on your tailnet running one of:
  - `opencode serve` (port 4096)
  - [claude-bridge](https://github.com/guitaripod/claude-bridge) in front of Claude Code (port 4098)

## Build

**iOS** — generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Tailscode.xcodeproj
```

Set your own `DEVELOPMENT_TEAM` in `project.yml`. Demo mode ("Try the demo" on first run, or `--demo`) populates scripted servers with no tailnet — same world on iOS, Linux, and Mac. DEBUG builds auto-connect from `TAILSCODE_HOST` / `TAILSCODE_PASSWORD`.

**Linux** — `scripts/dev-linuxapp.sh` keeps one harness display; `scripts/install-linuxapp.sh` puts a change in front of the person.

**macOS** — rsync + `xcodegen` + `xcodebuild` on a Mac (see `TailscodeMac/AGENTS.md`).

| Script | What |
|---|---|
| `scripts/parity.sh` | Capability matrix + anchor greps across all three clients |
| `scripts/shots.sh` | Marketing screenshots on a dedicated simulator |
| `scripts/film.sh` | Launch film capture + grade |
| `scripts/release.sh` | Archive + upload through the stable-macOS build VM |
| `scripts/build-mac.sh`, `scripts/run-mac.sh` | Drive a remote Mac over SSH for author-on-Linux workflows |
| `scripts/dev-linuxapp.sh` | Headless Linux client harness (never the real desktop) |

## Architecture

```
TailscodeCore/   Shared: parity, slash, splits, cascade, stores, demo world, themes contract
Tailscode/       iOS UIKit client
  App/           AppDelegate, SceneDelegate, AppCoordinator, push registration
  DesignSystem/  Theme — system materials, spacing, typography, haptics, Liquid Glass
  Logging/       AppLogger → OSLog + rotated file (Library/Logs/tailscode.log)
  Connection/    ConnectionController, tailnet discovery, manual connect
  Onboarding/    First-run connect flow with live probing, setup guide
  Home/          The board: live now, projects, recents, quotas, docked composer
  Sessions/      Cross-server session list, saved chats, file browser, background monitoring
  Chat/          ChatViewController + ViewModel, composer, cells, subagents, compaction,
                 model picker, slash palette, on-device prompt enhance
  Usage/         Plan gauges and quota detail
TailscodeLinux/  GTK4 desktop client (tiling, terminal, themes, slots)
TailscodeMac/    AppKit desktop client (tiling, Liquid Glass)
  Settings/      Servers, notifications, tailnet token, diagnostics, Pro
  Support/       Demo backend, Pro store, tour driver
TailscodeWidget/ ActivityKit widget (Lock Screen + Dynamic Island) + quota widgets
TailscodeNSE/    Notification service extension (push-driven widget reloads)
```

All networking, streaming and state live in [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit); the app renders `ConversationState` and forwards intent. If a capability is missing, it's added to the Kit — the app stays thin.

## Related projects

| Repo | What |
|---|---|
| [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) | The engine: Swift 6 package (GPL-3.0), Linux + Apple, unified opencode/Claude Code client, SSE streaming, `MessageReducer`, mockable backends, scriptable CLI |
| [claude-bridge](https://github.com/guitaripod/claude-bridge) | Hummingbird server that exposes Claude Code (`claude -p` stream-json) as structured HTTP sessions with SSE, subagents, compaction, usage and APNs pushes |

## License

[GPL-3.0](LICENSE)
