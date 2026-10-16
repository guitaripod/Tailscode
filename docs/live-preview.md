# Live preview: design and contract

Status: built 2026-10-14 to 16. All three clients draw the pane against a real Mac (Linux `PreviewPane`, Mac `PreviewSlotView`, iOS `PreviewViewController`); the lenses and touch are complete on Linux, the main desktop, and are `.gap` in the parity matrix (`previewLenses`, `previewTouch`) for the other two. Where a fact is measured it says where; where it is not, it says so.

## What it is

A pane that shows an iOS app running on a Mac's simulator, updated as the agent edits the code. The Mac does all the work (`previewd`, its own repo `guitaripod/previewd`); the client only draws a picture and the words around it. Apple's Xcode agreement (§2.7) bars making Xcode available over a network to several computers at once, so a host serves the one person whose Mac it is.

```
agent edits files ─▶ previewd (Mac): watch ─▶ xcodebuild ─▶ simctl install/launch ─▶ simulator (private device set)
                                                                                     │ sim-video stream (MJPEG, follows damage)
client pane ◀── PreviewRunner (Core) ◀── PreviewKit (Kit): JSON + length-prefixed frames + SSE ◀── previewd
```

## Moving parts

| Part | Where | What it does |
|---|---|---|
| `previewd` | `~/Dev/swift/previewd` | doctor (checklist + fixes), sessions, builds, frame stream, events; instant updates, history, compare, variants, the inspector; one daemon per home (kernel lock); orphan cleanup; idle reaper; bounded shutdown |
| `PreviewKit` | `CodingAgentKit` | `PreviewClient` (sessions, history, diff, replay, variants, inspect), the wire types, `FrameDecoder`, `HTTPClient.byteStream` (chunked bodies on both transports) |
| Core | `TailscodeCore` | `PreviewTarget` (address in the layout snapshot), `PreviewAccessStore`, `PreviewRunner`, `PreviewState`, `PreviewSlot`, `PreviewLight`, `PreviewReading` (every word), `PreviewRunner+Lenses`, `PreviewCompare`, `PreviewInspect`, `PaneKind.preview` |
| Panes | `PreviewPane` (Linux), `PreviewSlotView` (Mac), `PreviewViewController` (iOS) | draw the picture, the strip, the checklist; Linux also draws the lenses |

## Wire (proto 1)

- JSON over HTTP: `GET /status`, `/doctor`, `POST /fixes/:id`, `GET /fixes/:id`, `/projects?path=`, `/sessions`, `POST /sessions`, `GET|DELETE /sessions/:id`, `POST /sessions/:id/{rebuild,launch,appearance,contentsize}`, `GET /sessions/:id/frame.jpg`.
- Lenses: `GET /sessions/:id/history`, `/history/:n/picture.jpg`, `/diff?a=&b=`, `/replay?seconds=`; `POST /sessions/:id/variants`, `GET /variants/:job`, `/variants/:job/:n.jpg`; `POST /sessions/:id/inspect/:op` with `hello`, `tree`, `hit`, `audit`.
- `POST /sessions/:id/touch`: `{"action":"tap","x":0.5,"y":0.4}`, `swipe` (x, y, toX, toY, seconds), `text`, `key` (return, delete, escape), `button` (home); positions are fractions of the picture, origin top-left. Real HID events through the idb companion; `docs/touch.md` in previewd has the proto facts.
- `GET /sessions/:id/frames`: records `kind(1) length(4, big endian) payload`; kind 1 = 8-byte microseconds + JPEG, 2 = event JSON (the first is the session's `SessionInfo`), 3 = heartbeat every 5 s. A still screen sends nothing but heartbeats, so silence past 15 s is a dead link.
- `GET /sessions/:id/events`: SSE, `id:` is the event sequence, resumable with `?since=`.
- The wire types exist twice (`previewd/Sources/PreviewWire`, `CodingAgentKit/Sources/PreviewKit`) and must stay byte-identical; fixtures and live tests keep them honest.

## Measured (macbook, macOS 27.2, Xcode 27.1, iOS 27.0 runtime, load average 6–27)

| Fact | Result |
|---|---|
| Simulator refresh | `maximumFramesPerSecond` 60 on iPhone and iPad simulators; 60.0 fps delivered with `CADisableMinimumFrameDurationOnPhone`. Nothing here promises more. |
| Stream | `sim-video stream --encoding mjpeg --fps 0`: ~55–60 frames/s while animating, ~0–5 idle; 58 KB/frame at 1206×2622 q0.7, 17 KB at scale 0.5 q0.6 |
| Cold start | new session to live picture: 39 s (device create + boot 18 s, first build 12 s) |
| Edit to picture | 3.0 s (median of five, `build.start` ~0.9 s after save, build + install + launch 1.8–2.0 s); the first edit of a session took 9.6 s (cold caches) |
| Build error | reported in 3.2 s with file, line and message; last good picture stays; fixed edit back to live in 2.0 s |
| App killed | detected and reopened on the same screen in 0.2 s |
| Daemon killed | the next daemon clears the simulators it left; a second daemon for the same home refuses to start |
| Instant update | about 0.3 s on the host and about 1 s from save to changed pixels, against 3–4 s for a rebuild; a class that grew a field fell back to a rebuild (InjectionNext itself does not refuse it, so previewd compares the layout) |
| Inspector | `hello`, `tree` (15 views to depth 6) and `audit` (66 views visited) answer through the daemon on the sample app, which audits clean; `--flawed` plants a low-contrast hint, a 76×30 Save button and clipped rows, which the audit reports with measured values |
| Shutdown | SIGTERM with a session and open frame and event streams: exit in 8 s; before the streams observed shutdown the daemon outlived SIGTERM by more than a minute |
| Touch | warm tap request to 204 about 190 ms (60 ms is the hold); first touch of a session 1.1–1.6 s (the companion starts); typing 16 characters about 0.7 s; verified on an iPhone 17 Pro (402×874 pt) and an iPad Pro 13-inch (1032×1376 pt); click in the Linux pane to first changed pixel 0.25–0.4 s |
| Disk | a Mac with under 8 GB free refuses the preview and says so; at 100 % full simulators cannot even be deleted, which is how the gate was found to be needed |

## The ways to look

The picture is the first lens; the others read the same running app another way, are asked for only when a person opens them, and say why they are missing when they are.

| Lens | Answers | From |
|---|---|---|
| Look | what the app looks like now | the frame stream |
| Compare | what this edit changed: two kept pictures, differing regions outlined, how much of the screen they are | `/history` + `/diff` (ImageIO decode; macOS host only) |
| Rewind | the last seconds of the screen, scrubbed | `/replay` and the host's ring of frames |
| Matrix | the same screen in light and dark, two text sizes and right-to-left, side by side | `/variants` (appearance, content size and launch arguments, put back afterwards) |
| Inspect | the view under a point, its size, text, colours, spoken label and what it does | the in-app inspector (`PreviewInspect`) |
| Quality | text that is hard to read, controls under 44 points, cut-off text, views VoiceOver skips, with the measured values | `inspect/audit` |

Instant updates are a road, not a lens: a saved Swift file is compiled and linked alone from the build's own recorded command and swapped into the open app (InjectionNext 2.0.2RC3, pinned). `ChangeClassifier` and `LayoutFingerprint` send anything it cannot carry (a new stored property, a changed class layout, a new file, a resource) to the ordinary build, so the picture never runs half the old code. The strip names the road (`ReloadPath`).

The doctor offers instant updates and the inspector as optional rows (`DoctorCheck.optional`): a Mac without them is still ready, and `PreviewReading.isReady` ignores them. An app opened before the inspector was built is reopened once, by the host, when the inspector is first asked for.

## Touch

The pointer operates the app. A press and release is a tap, a drag is a swipe sent whole on release (the host draws it as steps, because the companion ignores a swipe's duration), the wheel is finger-direction swipes, the Keys chip forwards typing until Esc, and Home is the home button. `PreviewTouchReading` (letterbox math, tap versus swipe) and `PreviewTouchDriving` (scroll accumulation, batching, ordering) are Core and tested; the Linux pane draws the ripple, the busy ring while the host starts its input helper, and the drag trail. Touch is the person's to switch off, and is hidden when the host does not offer it. The coding agent has the same through MCP (`preview_tap`, `preview_swipe`, `preview_type`).

## Invariants

1. The host owns the simulator: it creates devices in a private set (`simctl --set`), names them `pv-<id>`, and deletes only those. Simulator.app shows only the default set and takes over the framebuffer of what it presents, so a private set is also what keeps the stream alive.
2. `sim-video` is pinned to idb 1.7.2 and a SHA-256; its stdin is held open because EOF is its stop order.
3. A picture is never blank: a failed build keeps the last good frame under a plain-words banner; the compiler's first error is one tap away.
4. Every failure is a state the runner recovers from, with backoff; none ends it. `PreviewRunner` attaches to the session already running for the app, so a second pane or client does not rebuild.
5. The light follows the activity doctrine: waking and reconnecting sweep, updating breathes, live, broken and offline hold still. It wears the existing `ActivityKind` badges.
6. A Mac is set up by a checklist the host proves, never a form; the one thing a person must do by hand is install Xcode, so that row opens the App Store on the Mac.

## Not done, said plainly

- Touch: long press, pinch, rotation and the lock, side and Siri buttons are not offered; a drag is not live (sent on release); each Backspace is its own request (~190 ms); the first touch of a session pays for starting the companion.
- Other platforms: tvOS and watchOS simulators stream the same way but are untried; visionOS has no runtime on the test Mac; a macOS app needs ScreenCaptureKit and a Screen Recording grant.
- Remote sync when the agent runs on a different machine from the Mac.
- The lenses and touch on the Mac and the phone (they draw the picture, the strip and the checklist; `previewLenses` and `previewTouch` are `.gap` there).
- Hot reload carries Swift code only; assets, storyboards and SwiftUI previews' macros are a rebuild.
