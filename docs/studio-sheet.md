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
- **Top inset** = the window's title-bar clearance (so the traffic lights and the chat title stay visible above the sheet) **+ 8 pt**, never less than 36 pt. **Left and right 24 pt. Bottom 0**: the sheet is attached to the bottom edge like a page sheet, which is what makes it read as rising out of the window rather than floating in it.
- The sheet is the full remaining rectangle; it follows the window as it is resized (same insets, the Studio's own responsive folds apply: shelf → strip under 960 pt wide, chips → Settings under 760 pt tall).
- Above 1,800 pt of window width the sheet stops growing at 1,752 pt and centres, so a very wide window does not stretch a 3:2 stage; below that it fills.
- **Toolbar inside the sheet** (there is no window title bar to borrow): lane switch leading, machine pill centred, queue count and **Done** trailing, 44 pt high, on the sheet's canvas; the same controls as the panel's toolbar, not new ones.

### 4.2 Scrim and context
A black scrim at 38 % over everything the sheet does not cover (the conversation, the sidebar, the composer; in a split, every pane). It takes presses: **a press on it closes the sheet** (a draft and a render survive; nothing is lost by a stray click). It never blurs.

### 4.3 Motion
- **Open:** the sheet travels from 28 % of its own height below its final position to rest while fading in, and the scrim fades 0 → 38 %, over **320 ms**, ease-out (a critically damped spring on Apple platforms, `ease-out-cubic` elsewhere). **Close:** the reverse over **220 ms**, ease-in. One timeline for both parts.
- The Studio's content is laid out at its final size **before** the motion starts and is moved as one layer (Mac: the sheet layer's transform; Linux: a `GtkRevealer` slide-up or an allocation-neutral translate) — nothing inside re-lays-out per frame, and the live sketch's layer keeps its contents.
- **Reduced motion:** a 120 ms cross-fade, no travel. The state machine is the same.
- Opening while already open (the composer's Image lane pressed again, a menu item): no animation, the lane changes and the words box takes focus.

### 4.4 Dismissal and the keys
- **Done**, **a press on the scrim**, **⌘W** (Mac) / **Ctrl+W** (Linux), and **Esc when no render is running** close the sheet.
- **Esc while a render is running stops it** (the Studio's existing rule, ⎋ = Stop), and the next Esc closes. This is one tested rule in Core (`StudioSheetKeys.escape(renderIsOut:)`), the same on every desk.
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

## 9. Mocks
`docs/studio-sheet-mocks/` — the sheet open over a conversation in dark and light, mid-open, and in a narrow window; the notes there say what looking at them changed.

## 10. Implementation (after §1–§9)
1. Core: `StudioSheetGeometry` (frames for a window size), `StudioSheetMotion` (durations, travel, scrim alpha, curve names), `StudioSheetState` and `StudioSheetKeys`, tests; a parity capability `.studioSheet` (Mac and Linux implement it, iOS answers its full-screen modal), strings.
2. Mac: `StudioSheetView` overlay in the main window's content, hosting the existing `StudioWorkspaceView`, replacing `StudioPanel`; menu validation; motion; selftests.
3. Linux: the sheet in the main window's overlay hosting both lanes in one stack; `ImageWindow`/`ForgeWindow` removed; chord routing; drive verbs and selftests updated.
4. Reshoot the landing's Mac and Linux Studio shots (the Studio now sits inside the window, so the shots become the whole Tailscode window with the sheet up), then the page's Studio figures.
