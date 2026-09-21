# Tailscode

**Your AI agents, anywhere.** A native remote for [Claude Code](https://github.com/guitaripod/claude-bridge), [Oh My Pi](https://github.com/guitaripod/omp-bridge) and [opencode](https://opencode.ai) running on your own machines: a universal iPhone and iPad app with the turn on your Lock Screen, and open-source desktop clients for Linux and the Mac. Point-to-point over your own [Tailscale](https://tailscale.com) tailnet — no relay, no account, no vendor backend. The transport's security is Tailscale's WireGuard, not something Tailscode implements. Screenshots, the full feature tour and pricing live at [midgarcorp.cc/tailscode](https://midgarcorp.cc/tailscode).

<p align="center">
  <a href="https://apps.apple.com/app/tailscode/id6791660932"><b>iPhone, iPad &amp; Mac — App Store</b></a> ·
  <a href="https://aur.archlinux.org/packages/tailscode"><b>Linux — AUR</b></a> ·
  <a href="https://github.com/guitaripod/Tailscode/releases"><b>Linux — tarball</b></a> ·
  <a href="https://midgarcorp.cc/tailscode">midgarcorp.cc/tailscode</a> ·
  <a href="LICENSE">GPL-3.0</a>
</p>

Latest releases: **iPhone 1.47** · **macOS 1.45** · **Linux 1.51**. Free is the whole core with one server; **Pro** is a one-time $14.99 purchase for unlimited servers, concurrent Live Activities and the delegate board.




## What it does

- **Every turn, live** — thinking, tool calls, subagents in place, diffs in the code's own colours, pictures the agent looked at. Prose is written out at an even pace, never re-wrapping under you.
- **Steer without leaving the chat** — allow once / always / deny cards, the agent's questions as a real form, follow-ups queued while it works, stop server-side. A turn that produced nothing says so.
- **Every machine, one list** — sessions across all your servers grouped by machine with live status; pin, archive, search inside transcripts across servers; a tailnet radar that finds the agent servers on your devices.
- **Models and money** — one chooser over every provider, per-prompt model and effort, session spend, the month's analytics merged across machines, quota walls scoped to their provider, Game Center trophies on Apple.
- **Compaction is a seam you can read**; `/design` opens a mock-up board; slash commands complete from the server's own catalog; the repo is read (branch, drift, diffs), never operated.
- **Delegate** — hand a packet down a ladder of cheaper models on the server and get a verified patch back.
- **Image and video** — describe a clip or paint from a reference on a tailnet machine running ComfyUI (Linux and iPhone paint; the Mac renders video only).
- **iPhone** — Lock Screen and Dynamic Island Live Activities pushed by claude-bridge, quota widgets and Control Center tiles, a home board, quick ask from the icon, haptics with meaning, on-device prompt enhance.
- **Desktops** — tiling splits with vim-grade verbs, a terminal, file tree, browser and video panes, a global chord that summons quick ask from any program, vim in the composer.
- **Eight themes with two faces each**, one typography ramp, ten languages, Liquid Glass where the platform draws it.


## Parity is a build gate

`TailscodeCore/Sources/TailscodeCore/Parity.swift` declares `AppCapability` — one case per user-facing capability, 149 today, each with a toolkit-free spec — and every client answers every case in its own `Parity.swift` with an exhaustive switch and no `default`. Adding a capability is a compile error in all three clients until each says what it does about it: `.implemented(anchor)`, `.partial`, `.gap(reason)`, `.notApplicable(reason)`, or on the Mac `.varies(direct:appStore:)`, because the ad-hoc build and the sandboxed App Store build are allowed different answers.

`scripts/parity.sh` prints the matrix and greps every claimed anchor inside that client's own tree, reading `#if TAILSCODE_MAS` the way the compiler does so the store column cannot claim code it compiles out. It runs as a Claude Code Stop hook, and both desktops assert it under `--selftest`.

```
$ scripts/parity.sh
capability                 iOS         linux       mac         mac-store
sessionSections            ok          ok          ok          ok
...
526/596 implemented, 15 partial, 18 gaps, 37 n/a
PARITY_OK
```

Exhaustiveness forces disclosure, not implementation — `.gap("later")` compiles. What it guarantees is that nothing can exist on one platform while the others say nothing.

## Requirements

- **iPhone and iPad** iOS 18+ (Liquid Glass and prompt enhance need iOS 26). **macOS** 26+. **Linux** GTK 4.12+ and libadwaita 1.4+ (Ubuntu 24.04, Debian 13, Fedora 40, Arch; not Ubuntu 22.04 or Debian 12); VTE, mpv and WebKitGTK add the terminal, video and browser panes.
- **Tailscale** on this device and on the machine the agent runs on.
- A machine on that tailnet running one of:
  - `opencode serve` (port 4096), opencode 1.18 or 2 — the app asks the server which API it speaks. One command sets it up as a service, gives it the password opencode 2 insists on, and keeps its model list current:

    ```bash
    curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash
    ```

  - [claude-bridge](https://github.com/guitaripod/claude-bridge) in front of Claude Code (port 4098) — also what makes Live Activity pushes possible.
  - [omp-bridge](https://github.com/guitaripod/omp-bridge) in front of [Oh My Pi](https://github.com/can1357/oh-my-pi) (port 4099).
- Optional: **ComfyUI** (port 8188) on the tailnet for image and video generation.

## Install

**iPhone and Mac** — [App Store](https://apps.apple.com/app/tailscode/id6791660932); one purchase covers both. The Mac can also be built ad-hoc, unsandboxed: `scripts/install-macapp.sh` replaces `/Applications/Tailscode.app`.

**Arch** — [tailscode](https://aur.archlinux.org/packages/tailscode) builds the `v1.51` tag; [tailscode-git](https://aur.archlinux.org/packages/tailscode-git) tracks master.

```bash
paru -S tailscode
```

**Other Linux** — the [release tarball](https://github.com/guitaripod/Tailscode/releases): one static-stdlib x86_64 binary plus desktop entry, icons, man page and completions, built in CI on `ubuntu-24.04` (needs nothing newer than `GLIBC_2.39`).

```bash
tar xf tailscode-1.51-linux-x86_64.tar.gz -C ~/.local --strip-components=2
```

The app watches the release feed and lights an update mark in its own chrome, then hands you the command for the way it was installed. A Flatpak manifest lives in `packaging/flatpak/` but is not on Flathub. On a Steam Deck use Desktop Mode with a keyboard; install Tailscale with the [deck script](https://github.com/tailscale-dev/deck-tailscale) first.

First run scans the tailnet for machines already answering — pick one and there is nothing to type.

## Build

**iOS** — `xcodegen generate`, then the `Tailscode` scheme in Xcode with your own `DEVELOPMENT_TEAM`. `--demo` (or "Try the demo" on first run) populates scripted servers with no tailnet; DEBUG builds auto-connect from `TAILSCODE_HOST` / `TAILSCODE_PASSWORD`.

**macOS** — `scripts/install-macapp.sh`. Design contract in `TailscodeMac/AGENTS.md`.

**Linux** — Swift 6.2, then:

```bash
sudo pacman -S --needed gtk4 libadwaita glib2 gdk-pixbuf2 libepoxy vte4 mpv webkitgtk-6.0 curl   # Arch
sudo apt install libgtk-4-dev libadwaita-1-dev libgdk-pixbuf-2.0-dev libepoxy-dev \
    libvte-2.91-gtk4-dev libmpv-dev libwebkitgtk-6.0-dev                                       # Debian, Ubuntu

TAILSCODE_KIT_REMOTE=1 scripts/package-linux.sh build      # static-stdlib binary
TAILSCODE_KIT_REMOTE=1 scripts/package-linux.sh tarball    # release artifact
tailscode --selftest                                        # headless end-to-end check
```

The manifests use CodingAgentKit from a sibling checkout when there is one and from its published tag otherwise. `scripts/parity.sh --check` is the gate; `scripts/release.sh` and `scripts/release-mac.sh` archive App Store builds through a stable-macOS build VM; `scripts/asc-*.py` drive App Store Connect.

## Architecture

```
TailscodeCore/       Shared, toolkit-free: parity registry, themes + typography, cascade
                     streaming, activity + presence, spend + analytics + trophies, git,
                     model fleet + quotas, splits + pane targets, slash + shortcuts,
                     quick ask + summon, image + video generation, design board, update
                     ledger, stores, demo world — 83 test files, 1,089 @Test functions
Tailscode/           iPhone and iPad UIKit client — connection, chat, home board, usage,
                     settings, Live Activity + widgets, push
TailscodeMac/        AppKit client — tiling, Liquid Glass, Metal presence orb, SelfTest
TailscodeLinux/      GTK4 client — a SwiftPM package (C shims for adw, vte, mpv, WebKit)
TailscodeWidget/     ActivityKit widget, quota widgets, controls
TailscodeMacWidget/  Mac quota widget
TailscodeNSE/        Notification service extension (push-driven widget reloads)
packaging/           Flatpak manifest, Arch PKGBUILDs, desktop entry, icons, metainfo
scripts/             Parity gate, packaging, dev loops, release, App Store Connect
```

Programmatic UIKit and AppKit, GTK4 through C shims, Swift 6 strict concurrency, no SwiftUI outside the widgets, no web views in the app. All networking, streaming and state live in [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) (pinned at 0.30.1); the clients render `ConversationState` and forward intent.

## Related projects

| Repo | What |
|---|---|
| [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) | The engine: Swift 6 package, Linux + Apple, one client over opencode 1.x/2.x, claude-bridge and omp-bridge, SSE streaming, `MessageReducer`, mockable backends, a CLI |
| [claude-bridge](https://github.com/guitaripod/claude-bridge) | Exposes Claude Code (`claude -p` stream-json) as HTTP sessions with SSE, subagents, compaction, spend, analytics, git and APNs pushes |
| [omp-bridge](https://github.com/guitaripod/omp-bridge) | The same wire protocol over Oh My Pi |
| [delegate](https://github.com/guitaripod/delegate) | The daemon that runs packets down a ladder of cheaper models |

## License

[GPL-3.0](LICENSE)
