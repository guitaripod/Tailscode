# TailscodeMac — design contract

Native AppKit client for remote coding agents, **macOS 26+ only**, Liquid Glass. Peer of the
iOS app and the GTK Linux app: same CodingAgentKit core, same TailscodeCore stores, same
`~/.config/tailscode/keybindings.json`. Feature parity is governed by the capability registry
(`TailscodeCore/Sources/TailscodeCore/Parity.swift` + this client's `Parity.swift` manifest —
see the `/parity` skill): every capability the Mac gains, loses, or renames must be answered
there, and `scripts/parity.sh` greps the anchors. When in doubt about a behavior, read the
spec in `CapabilityRegistry` and the richest existing implementation, and mirror the
semantics, not the toolkit.

## Non-negotiable conventions

- Programmatic AppKit. No storyboards, no xibs, no SwiftUI.
- `final class`; `@available(*, unavailable) required init?(coder:)` on every custom view/VC.
- **No inline `//` comments, no MARK, no file headers.** `///` doc comments on declarations only,
  written like the existing files (explain the *why*, not the what).
- Swift 6 strict concurrency. UI classes are `@MainActor`. Value types `Sendable`.
- Every user-facing string goes through `Localized.text(...)`.
- All persistence uses the same `tailscode.*` UserDefaults keys as Linux/iOS (see the stores in
  TailscodeCore). Do not invent new key names for existing concepts.
- macOS 26 APIs may be used unconditionally (deployment target is 26.0).

## Liquid Glass rules

Glass is for the floating control layer, never for content:

- The sidebar is a system-glass `NSSplitViewItem(sidebarWithViewController:)` — do not paint its
  background; rows stay transparent over the material.
- The toolbar is a standard unified `NSToolbar` — glass comes free.
- Floating above the transcript: the composer capsule, the status capsule, the jump-to-bottom
  pill, toasts. These use `MacTheme.glass(around:)` / `tintedGlass` / `glassGroup()`
  (NSGlassEffectView / NSGlassEffectContainerView). Neighbouring glass shapes that belong
  together share one `glassGroup`.
- The transcript itself is opaque `MacTheme.Color.canvas` (`textBackgroundColor`). Prose never
  sits on glass; glass never stacks on glass.
- The transcript scroll view extends under the floating composer/status layer with a matching
  `contentInsets.bottom`, so content scrolls behind glass (scroll-edge effect).
- Colors are system semantic + `MacTheme.Color.brand(_:)`. The app follows the system appearance
  and accent; named canvas palettes are Linux's job (GTK owns its chrome). Liquid Glass and system
  materials stay the Mac's theme.

## Architecture and file ownership

`MainWindowController` is the hub (the Mac's `MainWindow`): it owns the window, toolbar, split
layout, the shortcut engine, and current-chat state (`currentEntry`, `currentBackend`,
`conversation`); child controllers talk to it through closures set at construction.

| File | Owns |
|---|---|
| `main.swift` | flags: `--selftest`, `--version`, `--help`, `--connect`, unknown-flag guard |
| `AppDelegate.swift` | lifecycle only: activation, reconnect-on-active, opens `MainWindowController` |
| `MainMenu.swift` | the whole menu bar; every ⌘ equivalent lives here, one action per item |
| `MainWindowController.swift` | window, toolbar, split (sidebar / content column with the terminal under the transcript / files inspector), pane toggles + persistence (`tailscode.pane.*`), divider persistence (`tailscode.divider.*`), pane focus + Tab cycle, shortcut dispatch (`MacKeys.chord` → `ShortcutSet.resolve` → `perform(KeyAction)`), open/close of chats, new-chat creation, the servers/settings windows |
| `SidebarViewController.swift`, `SidebarRows.swift` | the chat list, full Linux parity |
| `FileTreePane.swift` | the files inspector: the server's tree via `FileBrowsingBackend.listFiles`, rooted at the open conversation's directory, lazy per-directory expansion, click-to-composer `@path` |
| `TerminalPane.swift` | the bottom terminal pane: `$SHELL -lc` one command at a time in the conversation's directory, ↑/↓ history, honest notice line, `ownsFocus` feeding the `.terminal` key context |
| `ServerDirectory.swift` | profiles + backends (+ `delete(id:)`, `entries()` with unreachable) |
| `TranscriptViewController.swift`, `TranscriptRows.swift`, `MacMarkdown.swift`, `ToolRowViews.swift`, `PendingCardViews.swift`, `ImageStore.swift`, `FindBar.swift` | the conversation |
| `ComposerView.swift`, `CompletionPopover.swift`, `PillsRow.swift`, `AttachmentChips.swift` | writing |
| `StatusBandView.swift`, `UsageViews.swift`, `ToastPresenter.swift` | status, usage, toasts |
| `ServersWindow.swift`, `SignInSheet.swift`, `NewChatSheet.swift`, `MacDialogs.swift`, `PreferencesWindow.swift` | server management, dialogs, settings |
| `MacKeys.swift`, `MacTheme.swift` | NSEvent→KeyChord adapter, tokens + glass helpers |
| `SelfTest.swift` | headless validation (`--selftest` over ssh) |

## Keyboard

Two layers, no overlap:
- ⌘ chords belong to `MainMenu.swift` (`MacKeys.chord` returns nil for ⌘ events on purpose).
- Everything else goes through the shared registry (`ShortcutSet` in TailscodeCore): a local
  `NSEvent` monitor in `MainWindowController` resolves normal/insert/terminal contexts exactly
  like Linux `installKeymap` + `composerNormalKey` (vim-normal composer = app normal mode, caret
  hidden, half-typed vim commands still land — see Linux `MainWindow.composerNormalKey`).

## Build & validate (from the Linux box)

```sh
cd /home/marcus/Dev/iOS/Tailscode
RS=(--exclude .git --exclude .build --exclude 'build*' --exclude DerivedData --exclude '*.xcodeproj')
rsync -az "${RS[@]}" ~/Dev/swift/CodingAgentKit/ macbook:Dev/swift/CodingAgentKit/
rsync -az "${RS[@]}" ~/Dev/iOS/Tailscode/ macbook:Dev/iOS/Tailscode/
ssh macbook 'bash -l -c "cd ~/Dev/iOS/Tailscode && xcodegen generate >/dev/null && \
  xcodebuild -project Tailscode.xcodeproj -scheme TailscodeMac -configuration Debug \
  -derivedDataPath build-tsmac build > /tmp/tsmac-build.log 2>&1; \
  grep -E \"error:|BUILD (SUCCEEDED|FAILED)\" /tmp/tsmac-build.log | tail -30"'
```

A change is done when that prints `BUILD SUCCEEDED` and, for logic with selftest coverage,
`--selftest` passes:

```sh
ssh macbook 'bash -l -c "TAILSCODE_HOST=<tailnet-ip>:4098 \
  ~/Dev/iOS/Tailscode/build-tsmac/Build/Products/Debug/TailscodeMac.app/Contents/MacOS/TailscodeMac --selftest"'
```
