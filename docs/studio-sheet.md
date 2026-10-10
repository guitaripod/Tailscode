# The Studio as a sheet — in the window, not beside it

Asked for: instead of a separate window, the image and video Studio opens as a modal that rises smoothly inside the Tailscode window and fills it, with padding at the top, left and right. Same order as before: **look** (§1), **think** (§2–§3), **design** (§4–§8, mocks in `docs/studio-sheet-mocks/`), then **implement** (§10).

## 1. What it is today

- **Mac:** `StudioWindowController` owns an `NSPanel` (1180×820, titled, resizable, miniaturizable) with the lane switch, machine pill, queue and Done in its toolbar. It is a second window: it floats among the user's other windows, can be buried under them, minimised, left behind on another Space, and takes the key window from the conversation. Closing it closes a window.
- **Linux:** two separate `GtkWindow`s — `ImageWindow` and `ForgeWindow` — each transient for the main window and *deliberately not modal* (their own source says why: every dialog the studio opens — file picker, save, viewer — would be a window over a modal window, and on X11 a modal over a modal hands the window manager a focus it will not grant, which locks the pointer for the whole session). Image and video are two windows, not two lanes.
- **iOS:** already a full-screen modal over Home; unchanged here.

## 2. What is wrong

1. **A second window is the wrong weight.** Making a picture is a task you start, watch and collect, not a place you work beside a conversation; a window competes with the chat for focus, Spaces, Stage Manager and Cmd-Tab, and the person has to find it again.
2. **The conversation is lost, or not hidden.** Beside the Studio the chat is still live and still takes keystrokes meant for the brief; behind it, it is simply gone. A modal with the chat dimmed above it says *where you came from* and what the Studio is for.
3. **Linux has no safe answer today** — the not-modal workaround is a symptom of putting a studio in a second toplevel.
4. **Image and video are two surfaces on Linux** while the Mac has one with a lane switch.

## 3. Principles

- **One window, one focus.** The Studio is part of the Tailscode window: the same Space, the same traffic lights, the same Cmd-W discipline. Nothing to find, bury or lose.
- **Modal in attention, not in time.** It owns the keyboard and the pointer while it is up, and a job never depends on it: closing never stops a render (the runner lives above the surface), and a finished render announces itself on the composer's lane mark when the sheet is closed.
- **Arrives and leaves by one motion, the same one.** A sheet rises from where a person already is (the bottom edge) and returns there; nothing jumps, nothing re-lays-out during the move.
- **Context stays visible.** A strip of the dimmed conversation (and the window's own title bar with its traffic lights) stays above the sheet, so the person never loses which chat the Studio was opened from.
- **The sheet is content; glass is the control layer.** On the Mac the sheet is an opaque canvas with its own rounded top corners; the toolbar controls and the brief dock are the floating glass layer exactly as in the panel (`TailscodeMac/AGENTS.md`). The scrim is a plain dim, never a blur or a material.

## 4. The design

### 4.1 Geometry
```
┌ window title bar (traffic lights, chat title)  — stays visible, dimmed ───────────┐
│  8 pt                                                                              │
│  ╭────────────── sheet (opaque canvas, 14-pt top corners) ──────────────────────╮  │
│  │ [Image | Video]        ● arch · Quality ready · ComfyUI 0.36 ▾    queue 0  Done │  │
│  │ stage …………………………………………………………………………………………………………   shelf       │  │
│  │ brief dock …………………………………………………………………………………………………………………………………………   │  │
└──┴──────────────────────────────────────────────────────────────────────────────┴──┘
 24 pt left/right; bottom flush to the window's edge (clipped by the window's own corner radius)
```
- **Top inset** = the window's title-bar clearance (so the traffic lights and the chat title stay visible above the sheet) **+ 8 pt** when the window is at least 720 pt tall (the gap is 0 below that, to keep the stage's room), never less than 36 pt. The traffic lights are the window's own and stay at full brightness; only the content under the scrim is dimmed. **Left and right 24 pt. Bottom 0**: the sheet is attached to the bottom edge like a page sheet, which is what makes it read as rising out of the window rather than floating in it.
- The sheet is the full remaining rectangle; it follows the window as it is resized (same insets). The Studio's own responsive folds are measured against **the sheet**, not the window: shelf → strip under 960 pt of sheet width (a window under ≈ 1,008 pt), chips → Settings under 760 pt of sheet height.
- **Edge:** the sheet is separated from the scrimmed conversation by a 1-pt hairline in the rule token along its top and sides and a soft shadow cast upward onto the scrim (blur 24 pt, 30 % black) — in the dark face the canvas is otherwise the same colour as the chat (1.05:1 once scrimmed).
- Above 1,800 pt of window width the sheet stops growing at 1,752 pt and centres (so the side margin is 24 pt up to 1,800 pt and grows after it), so a very wide window does not stretch a 3:2 stage; below that it fills.
- **Toolbar inside the sheet** (there is no window title bar to borrow): lane switch leading, machine pill centred, queue count and **Done** trailing, 44 pt high, on the sheet's canvas; the same controls as the panel's toolbar, not new ones.

### 4.2 Scrim and context
A black scrim — **38 % in the dark face, 26 % in the light face** (a black 38 % turns a white conversation into a muddy slab) — over everything the sheet does not cover (the conversation, the sidebar, the composer; in a split, every pane). It takes presses: **a press on it closes the sheet** (a draft and a render survive; nothing is lost by a stray click). It never blurs.

### 4.3 Motion
- **Open:** the sheet travels from 28 % of its own height below its final position to rest — **fully opaque from the first frame**, as a sheet is (a fade would show the conversation through the Studio) — while the scrim fades 0 → its alpha, over **320 ms**: a critically damped spring on Apple platforms, **ease-out-quad** elsewhere (cubic front-loads the travel: 91 % covered at 176 ms, so the move feels shorter than it is). **Close:** the reverse over **220 ms**, ease-in-quad. One timeline for both parts. Only under reduced motion does the sheet fade (a 120 ms cross-fade, no travel).
- The Studio's content is laid out at its final size **before** the motion starts and is moved as one layer (Mac: the sheet layer's transform; Linux: a `GtkRevealer` slide-up or an allocation-neutral translate) — nothing inside re-lays-out per frame, and the live sketch's layer keeps its contents.
- **Reduced motion:** a 120 ms cross-fade, no travel. The state machine is the same.
- Opening while already open (the composer's Image lane pressed again, a menu item): no animation, the lane changes and the words box takes focus.

### 4.4 Dismissal and the keys
- **Done**, **a press on the scrim**, **⌘W** (Mac) / **Ctrl+W** (Linux), and **Esc when no render is running** close the sheet.
- **Esc while a render is running stops it** (the Studio's existing rule, ⎋ = Stop), and the next Esc closes. This is one tested rule in Core (`StudioSheetKeys.escape(renderIsOut:)`), the same on every desk. It is made visible, not just correct: while a render is out the dock's Stop button wears the ⎋ key, and Done's tooltip and accessibility hint say *Press Esc to stop, again to close*.
- ⌘W / Ctrl+W closes the sheet first and only then, pressed again, the window. The window's red close button still closes the window.
- ⌘1/⌘2 lanes, ⌘↩ Generate, ⌘E Enhance, ⌘⇧R Again, ⌘S Save, ⌘⇧E Edit this, Space Open, ←/→ the shelf: unchanged. **Every chord that acts on the conversation behind the sheet** (Send, Archive, Archived Chats, the pane verbs, find-in-chat, new chat…) is **disabled while the sheet is up**: menu items validate to disabled, the Linux chord table is bypassed, so a stray keystroke can never reach a chat nobody can see the focus of.

### 4.5 Focus and accessibility
The sheet traps focus (Tab cycles inside; the words box is first responder on open; the opener — composer lane pill, menu item, toolbar mark — gets focus back on close). The content behind is hidden from assistive technology while the sheet is up; the sheet is announced as a dialog named *Studio* ("Studio, dialog"); a finished picture's polite announcement is unchanged. Pointer and focus rings are not hidden by the scrim logic.

### 4.6 What the sheet does not change
- **The pane slot** (`imageGenSlot`, a draw pane in the tiling) stays — it is the answer for someone who wants the picture *beside* a chat — and so does everything inside the Studio (stage, dock, shelf, lanes, machine sheet, keys).
- **iOS** keeps its full-screen modal; a phone has no window to be inside.
- The composer's Image/Video lane marks, the menu items and the toolbar mark all open the same sheet on the right lane (they called `presentStudio`/`presentImageStudio`/`presentForge` before and still do).

### 4.7 Linux specifics
One sheet hosts **both lanes** with the same lane switch as the Mac (the image surface and the forge surface become the two pages of one `GtkStack`; `ForgeWindow` and `ImageWindow` stop being windows). It is a child of the main window's overlay (`GtkOverlay`, as the hover verbs already are): scrim = a full-size box that captures presses, sheet = a revealer sliding up. Because there is **no second toplevel**, every dialog the Studio opens (reference picker, save, the picture viewer) is an ordinary transient of the one main window — which also removes the reason the old windows were not modal. Chords: the window-level key controller routes to the sheet first when it is up (4.4).

## 5. States
| State | Sheet | Scrim | Keys |
|---|---|---|---|
| closed | not in the tree | none | the conversation's |
| opening | travelling, content final | fading in | the sheet's (focus already inside) |
| open | at rest | 38 % | the sheet's; conversation chords disabled |
| closing | travelling out | fading out | the conversation's, as soon as the motion starts |
A pure state value in Core (`StudioSheetState`) so every client answers the same: `closed → opening → open → closing → closed`, with `show` while `opening/open` meaning "change lane, keep state" and `dismiss` while `closing` ignored.

## 6. Alternatives considered
- **Keep the panel and add chrome to dock it** — still a second window; rejected for the reasons in §2.
- **A native `NSWindow` sheet (`beginSheet`)** — macOS attaches it at the top, centred and sized to its content, with no scrim and no room for a full-size stage; rejected.
- **Full-bleed takeover with no padding** — loses the context strip and the sense that the chat is still underneath; the padding is what makes it a sheet and not a screen.
- **A bottom-aligned half sheet that resizes** — the stage needs the height; a half-height Studio is a worse Studio.

## 7. Risks
- **Mac key handling:** the Studio's key monitor claims ⌘↩/⌘E/⌘⇧E that are also chat chords; with the chat disabled while the sheet is up this becomes a simplification (the monitor can go) — verify the menu's validation, not just the monitor.
- **Mac glass:** the dock and toolbar controls are glass over the sheet canvas; the sheet itself is opaque, so no glass stacks on glass.
- **GTK:** the sheet's animation must not re-measure labels per frame (CLAUDE.md: live text never re-measures); translate/reveal only. `GtkRevealer` allocates the child at full size, so the transition is allocation-neutral for the content.
- **Small windows:** below 880×640 the sheet fills what exists (insets shrink to 0 on the sides under 700 pt of width) and the Studio's own folds apply.

## 8. Measures
Open and close take their stated times; a frame trace shows no layout pass inside the sheet during either; the sheet's frame equals `StudioSheetGeometry` for six window sizes (selftest); every conversation chord is disabled with the sheet up and re-enabled after it; reduced motion cross-fades; the pointer and the keyboard work after opening a file picker from the sheet on Linux with the session's real compositor (the X11 lock that motivated the old design must not return).

## 9. Mocks, and what looking at them changed

`docs/studio-sheet-mocks/` — the sheet open over a conversation in dark and light, mid-open, a geometry sheet with dimensions, a Linux window, a 960-wide window, the scrim at 30/38/45 %, and a 2,560-wide window (the conversation behind is the real shot; the Studio inside is recomposed in HTML around real crops, so read geometry and contrast from them, not pixels). Looked at:
- **The sheet had almost no edge in the dark face** (canvas 1.05–1.07:1 against the scrimmed chat at every scrim strength): added the hairline and the upward shadow (§4.1).
- **38 % is right for dark** (chat title 6.1:1, subtitle 3.0:1; 30 % lets the chat compete, 45 % drops the subtitle to 2.6:1) **and wrong for light**, where black turns a white chat into grey mud: 26 % there.
- **The top strip reads as context, not a gap — because the title bar is in it.** The traffic lights stay vivid and read as window chrome; the doc now says so. The 8-pt gap is only a seam; it goes away in short windows.
- **24-pt side insets read as a sheet, not a floating card, because the bottom is flush**; the bottom corners are a non-issue (the window's radius is about the inset).
- **Two stacked bars (title bar + sheet toolbar ≈ 104 pt) cost the stage.** At 1440×900 the stage is 62.4 % of the window (the old panel: 66.5 %) — over the 60 % line, barely. At 960×640 it falls to 46.8 % and the picture is small, so the short-window rules above (no gap, thresholds on the sheet) matter.
- **Ease-out-cubic hid the motion** (91 % of the travel done at 176 ms) and a fade would have shown the chat through the Studio: ease-out-quad and an opaque sheet.
- **Nothing said Esc stops before it closes:** the Stop button wears ⎋ and Done explains itself.
- **At 1,920 wide the 1,752-pt cap gives 84-pt sides** (§4.1 now says the side margin is 24 pt only up to 1,800); at 2,560 the centred sheet reads as a deliberate page.

## 10. The media viewer rides the same sheet

Asked for next: the media viewer opens like this modal too. What the viewer is today: on the Mac `ImageViewer` is a floating `NSWindow` (`GalleryWindow`) and the Video lane's *Open* opens a second player window; on Linux `ImageGallery` (the conversation's pictures) and `DrawViewer` (the Studio's) are two more `GtkWindow`s. The same two reasons apply — a viewer is something you look at and leave, and a window for it competes with the one the person is in — so it becomes a sheet:

- **One sheet machinery, two contents.** The sheet host (scrim, frame from `StudioSheetGeometry`, motion, state machine, key routing, conversation-chord lockout, focus trap, accessibility) stops being the Studio's and takes a *content*: the Studio workspace, or the gallery. A small stack manager owns up to two (`StudioSheetMetrics.maximumDepth`).
- **From the conversation:** a depth-0 sheet over the chat — same insets, same scrim. **From the Studio** (the verbs capsule's *Open*, a shelf tile's double-click, the Video lane's *Open full size*): a depth-1 sheet over the Studio — `stackInset` (12 pt) further in on the top and both sides so the Studio's edge shows above it; the scrim darkens the Studio only. Esc, ⌘W/Ctrl+W, Done and a press on the scrim close **the top sheet only**.
- **The viewer's canvas is the lights-down neutral** it has always been, in both faces (a picture is judged on a dark neutral); its toolbar row (44 pt) carries the filename and `n of m`, previous/next, the actions it already offers (Save, Copy, Open with…, Live Text where the platform has it) and Done. Nothing new is invented: same actions, same pager, same zoom (`+ − 0` and `1` for 1:1, double-click, scroll/pinch), Live Text unchanged.
- **Keys while a viewer is up:** ←/→/Home/End page, Space pages forward as today, Esc closes, ⌘C/Ctrl+C copies the picture, ⌘S/Ctrl+S saves; every conversation chord stays locked, and the Studio's own chords are locked while the viewer is on top of it.
- **Clips:** on the Mac the Video lane's *Open full size* plays the clip inside this sheet (an `AVPlayerView` with its controls, the same canvas) instead of a separate player window; Linux plays clips as it does today (mpv has no embeddable surface the sheet can own) and says so.
- **Not changed:** the iOS gallery (`ImageViewerViewController`) stays the full-screen paged modal it is; the Studio's own stage is not a viewer and does not become one.

## 11. Implementation (after §1–§10)
1. Core: `StudioSheetGeometry` (frames for a window size), `StudioSheetMotion` (durations, travel, scrim alpha, curve names), `StudioSheetState` and `StudioSheetKeys`, tests; a parity capability `.studioSheet` (Mac and Linux implement it, iOS answers its full-screen modal), strings.
2. Mac: `StudioSheetView` overlay in the main window's content, hosting the existing `StudioWorkspaceView`, replacing `StudioPanel`; menu validation; motion; selftests.
3. Linux: the sheet in the main window's overlay hosting both lanes in one stack; `ImageWindow`/`ForgeWindow` removed; chord routing; drive verbs and selftests updated.
4. Reshoot the landing's Mac and Linux Studio shots (the Studio now sits inside the window, so the shots become the whole Tailscode window with the sheet up), then the page's Studio figures.
