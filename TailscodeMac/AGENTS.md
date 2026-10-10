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

- **A sheet is the Mac's modal, and there is one host for every content** (`SheetView`, geometry and every number from Core's `StudioSheet.swift`; the Studio is `StudioSheetView`, a `SheetView` holding the workspace, and the media viewer is `MediaViewer`, another holding a gallery or a clip). `SheetPresenter` runs Core's `StudioSheetState` for one sheet and `SheetStack` owns the sheets that are up: at most `StudioSheetMetrics.maximumDepth`, the viewer opened from the Studio at depth 1 (`StudioSheetGeometry.frame(depth:)`, whose scrim darkens the Studio only and still takes every press), a third refused. Esc, ⌘W (`SheetStack.closesTop`), Done and a press on the scrim reach the top sheet only; the conversation's chords are off while any sheet is up and the Studio's own are off while a viewer is on it (`StudioWindowController.sheetOwnsKeys`). The viewer is the lights-down neutral in both faces (`MacTheme.Color.viewerGround`, its body forced dark) and has its own key table (`ViewerKey`, ← → Home End Space `+ − 0 1` ⌘C ⌘S Esc); a clip plays in it (`ClipPlayerView`) instead of a window of its own. It says what a press did in its own capsule, because it covers every place a toast would appear. **The Studio is a sheet inside the window, never a window of its own** (`StudioSheetView`). The scrim is a plain black dim — 38 % in the dark face, 26 % in the light — and never a blur or a material; the sheet is content (an opaque canvas with a hairline and an upward shadow for its edge) and the only glass in it is the brief dock's, as in a pane. It is moved as one layer, by its carrier's `sublayerTransform` (AppKit owns a view layer's own `transform`), after the workspace has been laid out at the final size, so a layout pass inside the sheet while it moves is a bug (`StudioWorkspaceView.layoutPasses` is how it is checked). While it is up the conversation's menu items are disabled (`MainMenu.answersWhileStudioIsUp` is the allow-list), the main window's key monitor and press routing stand down (`StudioSheetState.conversationChordsEnabled`), and ⌘W closes the sheet before the window. The Studio's own ⌘E/⌘⇧E/⌘↩ stay in the workspace's key monitor because AppKit stops at the first menu item wearing a chord even when it is disabled.

## Architecture and file ownership

`MainWindowController` is the hub (the Mac's `MainWindow`): it owns the window, toolbar, split
layout, the shortcut engine, and current-chat state (`currentEntry`, `currentBackend`,
`conversation`); child controllers talk to it through closures set at construction.

| File | Owns |
|---|---|
| `main.swift` | flags: `--selftest`, `--version`, `--help`, `--connect`, `--flight`, unknown-flag guard |
| `AppDelegate.swift` | lifecycle only: activation, reconnect-on-active, opens `MainWindowController` |
| `MainMenu.swift` | the whole menu bar; every ⌘ equivalent lives here, one action per item |
| `MainWindowController.swift` | window, toolbar, split (sidebar / content column with the terminal under the transcript / files inspector), pane toggles + persistence (`tailscode.pane.*`), divider persistence (`tailscode.divider.*`), pane focus + Tab cycle, shortcut dispatch (`MacKeys.chord` → `ShortcutSet.resolve` → `perform(KeyAction)`), open/close of chats, new-chat creation, the servers/settings windows |
| `SidebarViewController.swift`, `SidebarRows.swift` | the chat list, full Linux parity |
| `TerminalPane.swift` | the bottom terminal pane: `$SHELL -lc` one command at a time in the conversation's directory, ↑/↓ history, honest notice line, `ownsFocus` feeding the `.terminal` key context |
| `ServerDirectory.swift` | profiles + backends (+ `delete(id:)`, `entries()` with unreachable) |
| `TranscriptViewController.swift`, `TranscriptRows.swift`, `MacMarkdown.swift`, `ToolRowViews.swift`, `PendingCardViews.swift`, `ImageStore.swift`, `FindBar.swift` | the conversation |
| `TranscriptColumn.swift` | the rows, placed by frame so no constraint joins one row to another — never put the transcript back in a stack view |
| `MessageHoverBar.swift`, `ConversationWarmer.swift` | a message's verbs for a resting pointer; a chat started on hover or press before its click lands (a short glance lease on the hub's conversation, never an instance of its own) |
| `TileRuntime.swift` | the live pipeline: `MacHostClock` (one display link running `TileDrain`, paused when nothing is dirty, a 100 ms starvation guard, a pass that overruns its budget rests twice as long), `MacLiveEdges` and `TileRuntime` — the process `ConversationHub` (one `AgentConversation` per chat for every pane, watch and warm-up), pane leases and which pane drains a chat's queue, the background watch as a `.watching` lease, and the edge services once per chat per state (notifications, `TurnHandoff`, the atomic `SendQueueStore.takeFirst` drain, presence, redial of a stream the Kit gave up) |
| `PointerFeedback.swift` | `PointerPlate`, `PressSurface` (a pressable that is not a control), `HoverPlate` and `PointerSweep` (every button's plate) |
| `TranscriptBench.swift`, `Pace.swift` | `--bench <transcript.json …>` and the signposts plus `journey open` log that say where the time goes |
| `TileBench.swift`, `TileChecks.swift` | `--bench tiles=N[:R:K:S]` (N panes streaming the soak firehose in an ordered-front window: loop busy, worst slice, main-queue lag, footprint slope, frames applied against states folded, then a zoom) and the pipeline checks the selftest runs in a child (`--bench tiles-check`), because a transcript pane cannot be built under `--selftest` |
| `ComposerView.swift`, `CompletionPopover.swift`, `PillsRow.swift`, `ModelDialPopover.swift`, `AttachmentChips.swift` | writing — `PillsRow` carries the one dial pill for model and effort (`DialPill` + `EffortMeterView`, wheel steps the level), `ModelDialPopover` is the dial opened: models beside the effort ladder over Core's `ModelDialState` |
| `StatusBandView.swift`, `UsageViews.swift`, `ToastPresenter.swift` | status, usage, toasts |
| `MacImageStudio.swift`, `MacImageLibrary.swift` | the picture being made, held above every surface that shows it: slot, runner, sketch, decoded stage pictures, the machine's folder through a bounded lazily-decoded library; one shared and one per draw pane |
| `SheetView.swift`, `MediaViewer.swift`, `MediaViewerSurfaces.swift`, `MediaViewerLogic.swift`, `MediaViewerDemo.swift`, `MediaViewerChecks.swift` | the sheet host every modal content shares (scrim, carrier, canvas, edge, motion, focus trap), `SheetPresenter` and `SheetStack`, the media viewer (the gallery of the conversation's pictures and a clip's player, `ImageViewer.present` and `MediaViewer.play` its entry points), the pager, zoom and key table apart from any view, `--open viewer[:pictures\|loading\|clip]` and `--open studio:<state>+viewer`, and their selftest |
| `StudioWindowController.swift`, `StudioSheetView.swift`, `StudioWorkspaceView.swift`, `StudioLane.swift`, `ImageLane.swift` | the Studio's presenter (Core's `StudioSheetState` run over the lanes, the opener's focus, Esc, ⌘W), the sheet that rises inside the main window (scrim, canvas, toolbar row of lane switch, machine pill, queue and Done), the one arrangement of stage + shelf + dock the sheet and a draw pane share, the `StudioLane` seam and the Image lane behind it |
| `StudioStageView.swift`, `StudioDockView.swift`, `StudioDockParts.swift`, `StudioShelfView.swift`, `StudioMachineSheet.swift`, `DrawSlotView.swift` | the stage (sketch, picture, verbs capsule), the glass brief dock (chips, start-from slot, Enhance, rewrite card), the shelf rail/strip with drag-out, the machine sheet, a pane that paints |
| `VideoLane.swift`, `VideoStageView.swift`, `VideoBrief.swift`, `MacClipPosters.swift`, `StudioVideoLogic.swift`, `StudioVideoDemo.swift`, `ForgeRunner.swift`, `ForgeDemo.swift`, `ForgeMarkButton.swift`, `ForgeSetupSheet.swift` | the Video lane: `ForgeRunner` keeps the render, its socket and the board above every window; the lane draws the clip's stage (machine's sketch with a segment per pass, the finished clip played in place, one failure card), the clip shelf with posters, the brief (`VideoBrief` feeds the same dock the Image lane uses through `StudioBriefing`) and Animate this from the Image lane; `--open forge:<state>` stages every state; the toolbar mark and the renderer's setup sheet |
| `StudioBriefing.swift`, `StudioFiles.swift`, `StudioDrops.swift` | the seam the dock edits a brief through (words, pills, start-from, helper), what both lanes do with saved bytes and drops |
| `StudioLogic.swift`, `StudioChecks.swift`, `StudioDemo.swift` | toolkit-free shelf merge, stage states, verbs, chips, folds and keys with their selftest, and `--open studio:<state>` staging |
| `ServersWindow.swift`, `SignInSheet.swift`, `NewChatSheet.swift`, `MacDialogs.swift`, `PreferencesWindow.swift` | server management, dialogs, settings |
| `MacKeys.swift`, `MacTheme.swift` | NSEvent→KeyChord adapter, tokens + glass helpers |
| `Seatbelts.swift` | the one-second sample: sensors into `TileGovernor`, the level applied through `MotionBudget` (cascade instant at loaded, no animation at strained, the cascade link capped from busy) and `MemoryRelief`, the launch ledger and `RestorePlan`, the clean-exit record, SIGTERM as a quit |
| `LoopMeter.swift` | `MachClock`, and the main run loop's busy time from `CFRunLoopObserver`s on after-waiting / before-waiting into Core's `LoopLoad` |
| `Watchdog.swift` | a global-queue timer pinging the main queue; Core's `StallWatch` turns silence into stall and deep records with the main thread's CPU (`thread_info`) and the level-4 hint |
| `MemoryPressure.swift` | the kernel's memory-pressure source, `phys_footprint` against `min(8 GiB, 0.15 × physical)`, thermal state and Low Power Mode |
| `FlightWriter.swift` | Core's `FlightRing` written off the main thread at `~/Library/Logs/Tailscode/flight.ring` (the container in the store build), the launch header, `--flight [minutes]` |
| `RestoreBannerView.swift` | the safe restore's strip over the pane area: Core's sentence, Resume all / Resume one by one, dismiss |
| `DriveHooks.swift` | DEBUG `TAILSCODE_DRIVE` verbs for the seatbelts: `stall`, `spin`, `pressure`, `shed`, `level`, `flight`, `quit`, `kill` |
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
