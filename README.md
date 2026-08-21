# Tailscode

**One product, three native clients, parity enforced by the compiler.** Tailscode is an iPhone app (UIKit), a macOS app (AppKit) and a Linux app (GTK4 + libadwaita), built from one shared Swift core — no cross-platform framework, no web view, no lowest common denominator. Every user-facing capability is a case in a registry, and every client has to answer every case before it will compile.

Those clients drive remote coding agents — [opencode](https://opencode.ai) on port 4096 and **Claude Code** via [claude-bridge](https://github.com/guitaripod/claude-bridge) on port 4098 — running on machines you own. The app talks to them point-to-point over your own [Tailscale](https://tailscale.com) tailnet. No relay, no account, no vendor backend: there is no server of ours in the path, because there is no server of ours. The transport's security is Tailscale's WireGuard, not something Tailscode implements.

<p align="center">
  <a href="https://apps.apple.com/app/tailscode/id6791660932"><b>iPhone — App Store</b></a> ·
  <a href="https://github.com/guitaripod/Tailscode/releases"><b>Linux — release tarball</b></a> ·
  <b>macOS — build it yourself</b> ·
  <a href="https://midgarcorp.cc/tailscode">midgarcorp.cc/tailscode</a> ·
  <a href="LICENSE">GPL-3.0</a>
</p>

Current version **1.22** (build 51). The iPhone build is free; a one-time **$14.99 Pro** non-consumable unlocks multiple servers and concurrent Live Activities. iPhone only — there is no iPad build. The Mac client is ad-hoc signed and is not on the App Store; you build it from this repo.

Built on [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit), a GPL-3.0 Swift package that unifies both backends behind one conversation engine. The clients are polished shells; the engine is reusable.

## Why

Coding agents run long turns on machines that aren't in front of you. The phone is the remote control — full streaming transcripts, tool-call visibility, permission approvals, and Live Activities — so "prompt and bounce" actually works. The desktops are the multi-pane workspace: tiled chats, a terminal and file tree beside them, optional browser and video slots, vim in the composer.

<p align="center">
  <img src="marketing/desktop/linux-columns@1920.png" width="820" alt="The Linux client: two conversations tiled side by side with the file tree" />
</p>

<p align="center">
  <img src="docs/screenshot-streaming.png" width="240" alt="A live turn: the thinking, the code it wrote, the command it is running" />
  &nbsp;
  <img src="docs/screenshot-home.png" width="240" alt="Home: every agent and machine on one board, with a composer that starts the next chat" />
  &nbsp;
  <img src="docs/screenshot-code.png" width="240" alt="Markdown, syntax-highlighted code, and links rendered inline" />
</p>

## Parity is a build gate

Most cross-platform claims are a promise. This one is a switch statement.

`TailscodeCore/Sources/TailscodeCore/Parity.swift` declares `AppCapability` — **339 cases**, one per user-facing capability — plus a registry entry per case describing the capability in toolkit-free prose, so a port is judged against semantics rather than a screenshot.

Each client ships a manifest that switches over `AppCapability` **exhaustively, with no `default`**:

- `Tailscode/App/Parity.swift`
- `TailscodeMac/Parity.swift`
- `TailscodeLinux/Sources/TailscodeLinux/Parity.swift`

Adding a capability in Core is therefore a **compile error in all three clients** until each one says what it does about it. Four answers are allowed:

| Answer | Means |
|---|---|
| `.implemented("Anchor")` | Done here. `Anchor` is a type or function name that must exist **in this client's own tree** |
| `.partial("Anchor", missing: "…")` | Shipped, with named work still owed |
| `.gap("…")` | Not done, and the reason says what is actually in the way |
| `.notApplicable("…")` | A considered decision that the capability is meaningless on this platform |
| `.varies(direct:appStore:because:)` | The client ships two ways and the two answers differ — Mac only |

The Mac client ships twice: the ad-hoc build a person installs themselves, and the sandboxed one the App Store hands out, which is a smaller app on purpose. So the matrix has **four columns** — `iOS`, `linux`, `mac`, `mac-store` — and the last two read the same manifest, resolving a `.varies` to their own half. A capability may be better in the store column (`.updateCenter` is what installs the app there) as easily as worse.

`scripts/parity.sh` re-derives the case list from Core, rejects any `default:`, rejects grouped cases, demands an answer for every case, refuses an empty reason on any non-`implemented` answer, rejects a `.varies` in a client that ships one way, and greps each claimed anchor inside **that client's own directory only** — shared code existing in the Kit proves nothing about who wired it. A renamed type fails the gate. The anchor grep is distribution-aware: `scripts/lib/gating.awk` reads the source the way the compiler does, honouring `#if TAILSCODE_MAS` frames, so an anchor the store build compiles out cannot be claimed by the store column. `scripts/parity-hook.sh` runs it as a Claude Code Stop hook, so an agent cannot end a turn on an invalid manifest, and the two desktop clients assert the same invariants at runtime under `--selftest`.

```
$ ./scripts/parity.sh
capability                 iOS         linux       mac         mac-store
----------                 ---         -----       ---         ---------
sessionSections            ok          ok          ok          ok
...
411/460 implemented, 13 partial, 12 gaps, 24 n/a
PARITY_OK
```

Of the capabilities that differ:

- **20 are `notApplicable`**, each with a written argument. Fifteen are the desktop tiling/terminal/browser/video family that a phone screen has nowhere to put (`splitPanes`, `terminalPane`, `browserSlot`, `videoSlot`, `chatDragToPane`, `summonAnywhere`, `vimComposer`, `newPaneChooser`, `watchDirectory`, …). Linux opts out of `hapticFeedback` ("nothing under a desktop vibrates"), `usageWidgets` ("no Home screen, no lock screen accessory, no Control Center"), `homeQuickActions` and `gameCenter` ("Game Center is Apple's account system, and this client cannot sign into it"). macOS opts out of `homeQuickActions` alone.
- **5 are `partial`**, four of them on the Mac: `deepseekBalance` does not yet grey out spent rows in the model chooser; `hapticFeedback` has three canned trackpad patterns instead of composed cues; `gameCenter` renders but cannot authenticate, because the dev build is ad-hoc signed without the Game Center entitlement; `updateCenter` updates servers but cannot rebuild the running `.app`, so it prints the build command instead. On iOS, `tailscaleReadiness` collapses four daemon states into present-or-absent, because iOS cannot see whether the daemon is signed out or stopped.
- **2 are `gap`**: `auroraStream`, the GPU-written answer, exists on iOS only. Linux would need a Pango-replacing rasteriser and the Mac needs the glyph mapper rewritten against `NSLayoutManager`. Until then both desks use the settled renderer, which loses no meaning.

Be clear about what this buys: exhaustiveness forces **disclosure**, not implementation. `.gap("later")` compiles. What the gate guarantees is that no capability can quietly exist on one platform while the others say nothing, and that every exception is a paragraph somebody had to write and defend.

## What it does

**Chat**
- Streaming transcripts with collapsible **thought + tool activity groups**, syntax-highlighted code blocks (~60 languages, one toolkit-free lexer, byte-exact copy), real **markdown tables**, tappable links, and per-turn timestamps.
- **The answer is written, not pasted** — streamed prose plays out of a buffer at an evenly adapting pace, held at the last markdown-safe position so nothing flashes its asterisks, laid out once so no line ever re-wraps under the reader, with a heat-and-shimmer wave riding the newest characters at up to 120 Hz. On iOS there is a second renderer that hands the glyphs to the GPU; which hand writes is a setting you can watch change.
- **Optimistic sends** — your prompt echoes instantly, the thinking indicator engages in the same frame, and failures hand your text back instead of eating it.
- **Steering** — type while the agent runs to queue a follow-up; edit or cancel queued messages; stop aborts server-side.
- **Inline permission approvals** — Allow once / Always / Deny cards in the transcript; an approval answered on another device clears everywhere.
- **Answerable questions** — an agent's `AskUserQuestion` becomes a real form docked at the end of the transcript: single- and multi-select, a line to type an answer on beside the options, "Other…", skip.
- **Subagents render in place** — a spawned agent expands as a card at its own tool call, with its transcript and what it reported back; a wide fan-out collapses behind one row. A **task board** folds the agent's todo calls into one live checklist, and a **workflow card** shows a multi-agent run as phases with live agent rows.
- **Pictures the agent looked at** — every tool result that handed the model an image docks as an image bubble; tapping opens a paged gallery over every picture in the conversation, zoomable to 1:1, exporting the server's original bytes.
- **Compaction is a seam you can read** — `/compact` opens a preflight (it is irreversible and takes minutes) and lands as a divider showing what was traded for what, with the full summary behind it in a reader.
- **Diffs wear their language** — edit-tool calls and git patches get add/remove line washes with the code's own syntax colouring on top.
- **A turn that produced nothing says so**, and an interrupted one is marked as interrupted rather than left looking finished. A finished answer can report what it took: duration, tokens, throughput.
- **Find in transcript**, jump-to-message, fork a conversation, save a full local snapshot that still opens when the server is gone, message context menus (copy / quote / share), regenerate, per-session **drafts** persisted per keystroke.
- Slash commands with two halves done right: completion ranked over the **server's own catalog** while you type, and a typed command dispatched exactly as a picked one would be. The whole catalog is also **browsable**, grouped by where each command came from.
- Attachments: photos, files, and a clipboard that's read for what it is — copied files become chips, a picture becomes a chip, an overlong paste becomes a file, only words insert at the caret.
- **Prompt enhance** (iPhone) — hold Send to rewrite a rough prompt on-device with Apple's Foundation Models. Requires iOS 26; nothing leaves the phone.

**Models and money**
- **One model chooser over every server** — every provider's models in family sections, searchable, duplicate offers folded into one row with alternates, capabilities on the row, recents. A row says what picking it would change, and a model never offers a control it cannot do. The catalog is watched live, so models added by a server restart appear without relaunching.
- **Model identity tint** — every model family wears an authored hue and every effort level its heat, on chat rows, composer chips and effort controls. **Ultracode wears a rainbow**: the composer's edge burns with it on every desk watching the turn.
- **Quota walls, scoped** — exhaustion is a clear state with a one-shot alert and a chrome notice scoped to the chat's own provider; spent models draw dimmed-but-pickable in the chooser.
- **Session spend** — the chat's chrome carries what the whole conversation has cost, and touching it opens the account: per-turn bars, the four token tiers, per-model shares, the five priciest turns. Priced from the CLI's own transcript, **always marked an estimate**.
- **Usage analytics** — the month in numbers, merged across every connected server: daily bars, the week's rhythm, the day's clock, models, projects, tools, what caching saved, records, insights. A DeepSeek prepaid **balance** is read as money, not a bar.
- **Game Center trophies** (Apple clients) — the same ledger scored against a trophy catalog with achievements and leaderboards; sign-in is lazy and never a wall. See the parity notes for the Mac's signing limitation.

**Git — read, never operated**
- The conversation's repository: branch and upstream drift, triage-ordered sections (conflicts, staged, changed, untracked), per-path status letters, half-done merges named, per-file diffs — and a shorthand chip on the chat's chrome (`↑↓ ✖ + ~ ?`) read without opening it. Tailscode performs no git write operations of any kind: no stage, no commit, no branch, no push.

**Search**
- **Cross-server transcript search** — one query fans out to every connected machine's full CLI transcript history (subagents included) and merges into one ranked list with quoted matches.

**Sessions and servers**
- Unified session list across **multiple servers**, grouped by machine, with live status pills, search, swipe actions, context menus — and a busy row's second line naming the work actually in flight.
- **Pin** the chats that matter, **archive** device-locally, select several and act on all of them in one gesture. **Project boards** open a project as its own scoped list with a pre-aimed new-chat offer.
- **Tailnet radar** — the app asks the tailnet's own peers on both agent ports and draws the sweep; machines hold fixed bearings, configured ones say so, and a credential is asked for only where the tailnet can't be read locally.
- **A signed-out Claude is a state, not a reply** — the app shows the machine's account as a banner, and signing in splits the browser flow across the two machines: the server hands over the URL, this device opens it and returns the code. Never "open a terminal".
- **Updates are standing facts** — the app and every server report what they run and what they could run; one still mark in the chrome until each update is taken, one press installing a bridge end to end through its own restart, and the one-line install command handed over when a machine can't update itself. A server can also be **restarted** from the app, and set to update itself.
- First run is a checklist the app verifies, not a form — live tailnet status, both ports probed, every failure named with the one tap that fixes it.

**Quick ask**
- One gesture opens a bare composer aimed at your default server — starters, recents, slash commands, an effort control, attachments, and a draft that outlives the surface — for the question that shouldn't need setup. On iPhone it's in the icon's jump list and a Control Center tile; on the desktops a **global chord** (default Ctrl+Alt+A, recorded by pressing it, refused by name when it would break something else) summons it from any program.

**Themes and type**
- **Eight themes, two faces each** (Rosé Pine, Tokyo Night, Everforest, Gruvbox, Nord, Solarized, Suomi, Phosphor), authored for beauty and published through an OKLab contrast pass that fails the build rather than shipping an unreadable palette. The Apple clients also offer — and default to — **System**.
- **One typography ramp** — every piece of type names a role that carries face, weight, tracking, leading and digit width; the prompt is the heavier voice, the answer the lighter one, and a changing number is always tabular.

<p align="center">
  <img src="docs/type-ramp-before-after.png" width="820" alt="The typography ramp, before and after" />
</p>

**Home board** (iPhone)
- A board, not a server list: what's **live now**, the projects you work in, recent chats with unread badges, and your plan gauges — refreshed while you look at it. A **docked composer** starts a chat before one exists: pick project, server, model and effort, type, send.
- The app icon's jump list (New Chat, Saved, Usage, Quick Ask, a dynamic Resume) and a **missed-activity inbox** that keeps every alert listed until you've looked at it.

**Desktop workspace** (Linux and Mac)
- **Tiling splits** with vim-grade pane verbs, zoom, an even grid for a marked set of chats, and drag-a-chat-into-a-pane with a live preview. An empty pane asks which server, then which chat. The layout — including what a browser or video slot was showing — survives restarts.
- Panes beyond chat: a **terminal**, a **file tree**, a **browser slot** (the platform's own engine, claiming only browser chords), and a **video slot** (libmpv on Linux, AVKit on Mac) whose empty state is a board of what's live on your followed channels.
- **Where you press is what you're working in** — clicks route from the window itself, so focus follows intent without stealing the press's meaning.
- Rebindable **shortcut registry** with contexts, sequences, conflict reporting, and a cheatsheet derived from the effective bindings.

**Live Activities and notifications** (iPhone)
- Per-session **Lock Screen** and Dynamic Island activities with live phase (thinking / running tool / writing / awaiting approval), elapsed timer and tool counts.
- claude-bridge pushes updates over APNs, so the Lock Screen keeps ticking while the app is suspended. **Plain opencode has no push path** — against a bare `opencode serve`, an activity updates while the app can run, not from the server. Approval requests alert; finished turns linger with the outcome.
- **Tap to deep-link into that exact chat.** Every notification type is individually switchable.

**Widgets** (iPhone and Mac)
- Quota widgets in every size — small, medium, large, and the iPhone's **Lock Screen** rectangular, circular and inline accessories — plus Control Center controls for usage and Quick Ask. Providers, rows, detail level, accent and reset clock are configurable per widget.
- An app group and keychain access group let the timeline fetch Claude and Grok numbers itself, so the reading refreshes without opening the app. `TailscodeMacWidget/` puts the same reading in Notification Center.

**Fit and finish**
- Liquid Glass (iOS 26) composer, FAB and banners with material fallbacks; Dynamic Type; localized into **ten languages** (de, en, es, fr, it, ja, ko, pt-BR, zh-Hans, zh-Hant).
- **Haptics with meaning** (iPhone) — named cues led by the waiting group (send, step, needs-you, received), authored to stay pleasant at full strength, all scaled by one intensity slider that plays every stop it passes.
- **Presence orb** — alpha, opt-in, off by default, and it tells you it costs battery when you turn it on. A small GPU-rendered creature that breathes for work, knocks when something needs you, and holds still for failure.
- File-based diagnostics logger with an in-app colorized viewer and a shareable report.

## Clients

| Client | Toolkit | Floor | Source |
|---|---|---|---|
| **iPhone** | UIKit, programmatic. No SwiftUI in the app target (only in the widgets, which WidgetKit requires) | iOS 18; Liquid Glass and prompt enhance need iOS 26 | `Tailscode/` — 115 files, 42,949 lines |
| **macOS** | AppKit. Carbon for the global hotkey, WebKit, GameKit, MetalKit | macOS 26 | `TailscodeMac/` — 70 files, 31,152 lines |
| **Linux** | GTK4 + libadwaita through C shims. VTE, libmpv and WebKitGTK compiled in only if their headers exist | GTK 4.12 / libadwaita 1.4 | `TailscodeLinux/` — 77 files, 30,023 lines |
| **Shared core** | Foundation only. Zero UIKit, AppKit, GTK or SwiftUI imports | Swift 6 language mode | `TailscodeCore/` — 111 files, 30,392 lines |

385 first-party Swift files, 136,593 lines. The shared core carries 52 test files and **679 `@Test` functions** (swift-testing, 9,563 lines) — themes and the type ramp fail the build rather than drift. All of those tests live in Core: there is no UI test target on any client, and the renderings are held to account by the anchor greps and by the desktop selftests (`TailscodeMac/SelfTest.swift`, 19 check groups; the Linux one, 33), both of which include the parity check. The iPhone client has no runtime selftest; exhaustiveness still gates its compilation.

## Requirements

- **iPhone** — iOS 18+. iPhone only (`TARGETED_DEVICE_FAMILY 1`); there is no iPad build.
- **macOS** — 26+.
- **Linux** — **GTK 4.12+ and libadwaita 1.4+**. Ubuntu 24.04, Debian 13, Fedora 40 and Arch all clear it; **Ubuntu 22.04 and Debian 12 do not**. Optional VTE, mpv and WebKitGTK add the terminal, video and browser panes.
- **Tailscale** on this device and on the machine the agent runs on. Tailscode does not ship a transport of its own and does no relaying; if the two machines cannot see each other on the tailnet, there is nothing to fall back to.
- A machine on that tailnet running one of:
  - `opencode serve` (port 4096) — one command sets it up as a service and keeps its model list current, which a long-lived opencode server does not do on its own:

    ```bash
    curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash
    ```

  - [claude-bridge](https://github.com/guitaripod/claude-bridge) in front of Claude Code (port 4098). This is also what makes Live Activity pushes possible.

## Install

### iPhone

[App Store](https://apps.apple.com/app/tailscode/id6791660932). Free; Pro is a one-time $14.99 non-consumable for multiple servers and concurrent Live Activities. Optional tips are $2.99 / $9.99 / $19.99.

### Linux

The GitHub release tarball is the only published channel today. It is one static-stdlib binary plus its desktop entry, icons, man page and completions, built in CI on `ubuntu-24.04` under `swift:6.2-noble`; the job fails if the binary needs anything newer than `GLIBC_2.39`, or if the VTE/mpv/WebKit headers are missing, so a release never silently drops a pane. **x86_64 only** — no aarch64 build is published.

```bash
tar xf tailscode-1.21-linux-x86_64.tar.gz -C ~/.local --strip-components=2
```

`--strip-components=2`, not 1: the archive members are `./usr/bin/tailscode`, so stripping one level lands the binary at `~/.local/usr/bin`.

A Flatpak manifest (`packaging/flatpak/`) and Arch PKGBUILDs (`packaging/arch/`) are in the repo but **not published** — Tailscode is not on Flathub and not in the AUR. Until it is, build the Flatpak from the manifest or install from source.

**Steam Deck** — Desktop Mode, install from the tarball or a locally built Flatpak, then add it to Steam so it appears in Game Mode. Tailscale itself is a system service and cannot be a Flatpak; install it with the [deck script](https://github.com/tailscale-dev/deck-tailscale) first. The app is at its best docked to a monitor with a keyboard: Game Mode's on-screen keyboard cannot type into GTK text fields ([Valve bug](https://steamcommunity.com/app/1675200/discussions/1/3370405364916738938/)).

First run checks what it can: whether this machine is on a tailnet, and which machines on it are already answering — pick one from the scan and there is nothing to type.

### macOS

No artifact is distributed. On a Mac running macOS 26+:

```bash
scripts/install-macapp.sh            # xcodegen + xcodebuild -scheme TailscodeMac -configuration Release
scripts/install-macapp.sh --launch   # and open it
```

That builds Release, replaces `/Applications/Tailscode.app`, **ad-hoc signs it**, and prints its version. Ad-hoc signing is why the Mac client cannot authenticate Game Center and why its update centre hands you a build command instead of updating itself.

## Build

**iOS** — generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Tailscode.xcodeproj    # scheme Tailscode, iOS 18+
```

Set your own `DEVELOPMENT_TEAM` in `project.yml`. Demo mode ("Try the demo" on first run, or `--demo`) populates scripted servers with no tailnet — the same world on iPhone, Linux and Mac. DEBUG builds auto-connect from `TAILSCODE_HOST` / `TAILSCODE_PASSWORD`.

**Linux** — from a clean clone, with a Swift 6.2 toolchain (the manifests declare tools 6.0; CI builds on 6.2):

```bash
# Arch
sudo pacman -S --needed gtk4 libadwaita glib2 gdk-pixbuf2 libepoxy vte4 mpv webkitgtk-6.0 curl
# Debian, Ubuntu
sudo apt install libgtk-4-dev libadwaita-1-dev libgdk-pixbuf-2.0-dev libepoxy-dev \
    libvte-2.91-gtk4-dev libmpv-dev libwebkitgtk-6.0-dev

TAILSCODE_KIT_REMOTE=1 scripts/package-linux.sh build             # static-stdlib binary
TAILSCODE_KIT_REMOTE=1 scripts/package-linux.sh install <destdir>  # full install tree
TAILSCODE_KIT_REMOTE=1 scripts/package-linux.sh tarball            # release artifact
tailscode --selftest                                               # headless end-to-end check
```

The manifests use CodingAgentKit from a sibling checkout when there is one and from its published tag otherwise, so a clone builds without arranging anything.

**macOS** — `scripts/install-macapp.sh` on the Mac itself, as above. Design contract in `TailscodeMac/AGENTS.md`.

| Script | What |
|---|---|
| `scripts/parity.sh` | Capability matrix + anchor greps across all four columns (three clients, two Mac distributions). `--check` is the gate |
| `scripts/lib/gating.awk` | Reads a source file the way the compiler does, honouring `#if TAILSCODE_MAS`, so the store column cannot claim an anchor it compiles out |
| `scripts/parity-hook.sh` | The same gate, wired as a Claude Code Stop hook |
| `scripts/package-linux.sh` | Linux build / install tree / release tarball |
| `scripts/install-linuxapp.sh`, `scripts/dev-linuxapp.sh` | Linux dev loop: rebuild against a sibling Kit and restart; headless harness display |
| `scripts/install-macapp.sh` | Build TailscodeMac Release and replace `/Applications/Tailscode.app` |
| `scripts/build-macapp.sh` | From Linux: rsync to a Mac over Tailscale, Debug build, run `TailscodeMac --selftest` as the proof |
| `scripts/build-mac.sh`, `scripts/run-mac.sh` | From Linux: build the **iOS** app on a remote Mac for the Simulator, install it, take screenshots |
| `scripts/record-linuxapp.sh`, `scripts/shots.sh`, `scripts/film-*.{sh,py}` | Screenshots and the launch-film rig |
| `scripts/release.sh` | Archive + upload through the stable-macOS build VM |
| `scripts/asc-*.py` | App Store Connect suite: builds, releases, screenshots, products, Game Center |

## Architecture

```
TailscodeCore/       Shared, toolkit-free: parity registry, themes + typography, cascade
                     streaming, activity + presence, spend + analytics + trophies, git,
                     model fleet + quotas, splits + pane targets, slash + shortcuts,
                     quick ask + summon, update ledger, stores, demo world
  Tests/             52 files, 679 @Test functions (swift-testing)
Tailscode/           iPhone UIKit client
  App/               AppDelegate, SceneDelegate, AppCoordinator, push, Parity manifest
  DesignSystem/      Theme — system materials, spacing, type ramp, haptics, Liquid Glass
  Logging/           AppLogger → OSLog + rotated file (Library/Logs/tailscode.log)
  Connection/        ConnectionController, tailnet radar, manual connect
  Onboarding/        First-run connect flow with live probing, setup guide
  Home/              The board: live now, projects, recents, quotas, docked composer
  Sessions/          Cross-server session list, saved chats, file browser, monitoring
  Chat/              ChatViewController + ViewModel, composer, cells, subagents,
                     compaction, model chooser, slash palette, prompt enhance
  Git/               Repository status + diff readers (read-only)
  Usage/             Plan gauges, quota detail, analytics, spend, trophies
  Settings/          Servers, notifications, themes, haptics, diagnostics, Pro
  Support/           Pro store, tour driver, shared UI components
  LiveActivity/      ActivityKit plumbing
  Resources/         Assets, Localizable.xcstrings (10 languages)
TailscodeMac/        AppKit client — tiling, Liquid Glass, Metal presence orb, SelfTest
TailscodeLinux/      GTK4 client — a SwiftPM package (C shims for adw, vte, mpv, WebKit)
TailscodeWidget/     ActivityKit widget (Lock Screen + Dynamic Island), quota widgets, controls
TailscodeMacWidget/  Mac quota widget
TailscodeNSE/        Notification service extension (push-driven widget reloads)
packaging/           Flatpak manifest, Arch PKGBUILDs, desktop entry, icons, metainfo
scripts/             Parity gate, packaging, dev loops, App Store Connect, film rig
```

All networking, streaming and state live in [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) (pinned at 0.17.0); the app renders `ConversationState` and forwards intent. If a capability is missing, it's added to the Kit — the app stays thin.

## Related projects

| Repo | What |
|---|---|
| [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) | The engine: Swift 6 package (GPL-3.0), Linux + Apple, unified opencode/Claude Code client, SSE streaming, `MessageReducer`, mockable backends, scriptable CLI |
| [claude-bridge](https://github.com/guitaripod/claude-bridge) | Hummingbird server that exposes Claude Code (`claude -p` stream-json) as structured HTTP sessions with SSE, subagents, compaction, spend, analytics, git, and APNs pushes |

## License

[GPL-3.0](LICENSE)
