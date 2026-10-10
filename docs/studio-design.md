# Studio — the image and video suite, looked at, thought through, designed

Order of work, as asked: **look** (§1), **think** (§2–§4), **design** (§5–§8, with the mocks in `docs/studio-mocks/`), then **implement** (§9). Nothing in §9 starts before §1–§8 are written down.

## 1. What I looked at

Screens captured from the code as it stands, against the mock ComfyUI (`scripts/mock-comfyui.py`) and the staged forge states:

| Client | Image | Video |
|---|---|---|
| iOS (sim, `TAILSCODE_OPEN_IMAGE`, `--video`) | A modal "Image": title, one line of machine facts, an almost empty white stage card holding a green dot and the prompt while it waits, the machine's shelf of six pictures half hidden behind the composer, a one-row scrolling chip bar, Stop. | A modal "Video": a grey stage with a dot and "Second pass", a percentage badge and a bar below, the prompt as a caption, Size / Length / Smoothness / Seed chips whose values are cut off by the bottom bar, Stop. |
| Linux (harness, `draw`, `forge`) | A pane: "Nothing painted yet", four starter cards, a four-across shelf of the machine's pictures cropped at the foot of the pane, then a chip row (engine, aspect, megapixels, Enhance, Helper, Add a reference, More), the words box, Generate and a one-line cost note. | A pane with the full set: stage with the live sketch, Enhance + rewrite card, start-from picture, continue-a-clip, sound. |
| macOS (`--open forge:drafting|running|done --shot`) | **Nothing.** The image suite does not exist on the Mac. | A sheet with a black rectangle for a stage, a right-hand column of stock controls that overlap their own labels, a row of tiny text-only shelf chips, a "Done" button stranded in the bottom corner, a lot of unused window, no Enhance, no live sketch, no start-from. |

## 2. What is wrong, in order of how much it costs the person

1. **The stage is the point, and it is the emptiest thing on screen.** A render is one to two minutes of somebody's card. For that whole time the Mac shows a black box with a film glyph, and the phone a grey card with a dot. The machine *is* sending the picture as it forms (ComfyUI streams a sketch every sampler step; `ImageGenPreviewFrame`, `ForgeJob.sketch`) and only Linux draws it.
2. **Two surfaces for one machine.** Image and Video are separate windows with separate machine bars, separate shelves and separate vocabularies for the same ComfyUI (`ImageGenDoor` already inherits the video renderer's address because one ComfyUI holds both model sets). A person who paints a frame and then animates it crosses two doors.
3. **The controls are a form, not a brief.** The Mac's right column and the phone's chip bar present the same nine decisions as a stack of boxes. Words — the one thing a person actually writes — get the same visual weight as the seed.
4. **The shelf is an afterthought.** What the machine has made is the account of the work, and it is drawn as text chips (Mac), a strip hidden behind the composer (phone) or a grid cropped by the pane edge (Linux). Thumbnails of pictures and clips are the entire value of a shelf.
5. **A finished picture does not say what can be done with it.** Save, share, copy, again, edit this (`ImageGenAction`) exist; nothing on the stage offers them where the eye already is.
6. **Facts the person needs are buried.** Whether this machine can paint Quality or only Speed, whether it is asleep, how long this will take: one grey line in a subtitle.
7. **The Mac has no hands.** No keyboard (generate, stop, walk the shelf), no drag of a reference in, no drag of a result out, no menu.

## 3. Principles this design holds itself to

- **Stage first.** The output owns the window. Everything else supports it; at the default size the stage is at least 60 % of the area.
- **The brief reads like a sentence**, left to right: [start from] [words] [how] [go]. The words box is the largest control on the page.
- **One shelf.** What this machine has made, newest first, always with its picture; the picture just made is on stage and in the shelf at the same time, so the session and the machine's folder are one thing (`ImageGenLibrary` already says this).
- **Narrated, honest waits.** Words from Core's `ImageGenProgress` / `ForgeJob`; a bar only from the sampler's own count and never sitting at zero; the sketch when the machine sends one; nothing invented. Work breathes on one slow swell, a settled state holds perfectly still (the activity doctrine).
- **Same words, same order on every desk** — the fields are Core's (`ImageGenField`, `ForgeField`), and so is every sentence. A client decides how a thing is drawn, never what it is called.
- **Closing never stops the work.** The job lives above the surface; the surface says so and finds the picture exactly where it was on return.
- **Chrome follows the platform contract.** Mac: opaque canvas for content, glass only for the one floating control layer, never stacked, no `NSVisualEffectView` backing (`TailscodeMac/AGENTS.md`); tokens and type roles only.

## 4. The model of the thing (what the screen must be able to say)

States of the stage, shared by both lanes (image = `ImageGenSlot`, video = `ForgeBoard/ForgeJob`):

| State | Stage | Brief dock | Shelf |
|---|---|---|---|
| **Empty** | the machine's most recent picture/clip held dimmed behind four starter ideas; the drop target ("Describe a picture, or drop one here to edit") | enabled; Generate disabled until words exist | the machine's folder |
| **Drafting** | the chosen start-from picture (if any) at full size; otherwise as Empty | words focused; chips live; estimate line ("about 1 min 20 s on arch") | unchanged |
| **Waiting** | the last frame held; one sentence from Core ("Behind 2 renders · 41 s") on a breathing glyph | Stop replaces Generate; words/chips read-only and dimmed | unchanged, a placeholder tile for the job leads |
| **Loading model / reading words / reading the picture** | same, the sentence changes | same | same |
| **Painting** | **the live sketch fills the stage**, captioned "Sketch · step 12 of 28"; a 2-pt progress line docked to the stage's bottom edge from the sampler's count | same | the placeholder tile shows the sketch too |
| **Decoding / saving** | the sketch dims slightly, "Saving…" | same | same |
| **Done** | the sketch **crossfades once** to the finished picture/clip; the verbs dock under it (glass capsule on Mac); caption: words, seed, steps, seconds | Generate returns, "Again" is its sibling | the tile settles into place, selected |
| **Failed / machine asleep / files missing** | one honest sentence from Core with the tone of failure (danger, perfectly still) and the one remedy (Retry / Wake / Machine…) | enabled | unchanged |
| **Stopped** | the last picture held; "Stopped" | enabled | unchanged |

Decisions the person makes (Core's list, unchanged): image — engine, aspect, size, quality, cutout, avoid, seed, references (up to the engine's limit); video — size, length, smoothness, sound, avoid, seed, start-from (a picture, the machine's gallery, or the end of an earlier clip).

## 5. The design

### 5.1 One Studio on the desktops, two lanes

A single **Studio** window (Mac: an `NSPanel`, not a sheet, so it can sit beside a conversation; Linux: the existing image/forge windows adopt the same anatomy). A segmented lane switch, **Image | Video**, sits in the toolbar's leading position and swaps the stage, dock and chips while the **shelf, the machine pill and the queue stay put**. A person who paints a frame and animates it never changes windows: *Animate this* on a picture moves to the Video lane with that picture as the start-from.

### 5.2 Anatomy (default 1180 × 820, minimum 880 × 640)

```
┌ toolbar: [Image | Video]        ● arch · Quality ready · ComfyUI 0.36 ▾        queue 0   Done ┐
│ ┌──────────────────────────────────────────────────────────────┐ ┌ shelf ┐
│ │                                                              │ │ ▢     │  vertical filmstrip,
│ │                         STAGE                                │ │ ▢     │  88-pt thumbnails,
│ │        (sketch / picture / clip, aspect-fit, no chrome)      │ │ ▢  …  │  newest first
│ │                                                              │ │       │
│ │   ╭ Save  Share  Copy  Again  Edit this ╮  (glass capsule,   │ │       │
│   ─────────── progress line on the stage's bottom edge ────── │ │       │   on the stage, over the picture's lower margin) 
│ └──────────────────────────────────────────────────────────────┘ │       │
│   caption: "a lighthouse on a cliff at dusk · seed 481723 · 28 steps · 41 s"                │
│ ╭ brief dock (glass, floating, 16 pt from the edges) ───────────────────────────────────────╮ │
│ │ [▣ start from]  Words…                                          (Enhance ▾ helper)   [Generate ⌘↩] │
│ │ [Quality ▾] [3:2 ▾] [2 MP ▾] [Cutout] [Avoid…] [Seed 481723 ⟳] [+ reference]   about 1 min 20 s │
│ ╰──────────────────────────────────────────────────────────────────────────────────────────╯ │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Stage** — opaque canvas token, 16-pt corner radius, picture aspect-fit with a 24-pt margin; no border. The stage never changes size while a job runs: the finished picture arrives into the same rectangle the sketch used (the aspect is decided before the render starts), so nothing moves when it lands.
- **Verbs** — a glass capsule floating at the stage's bottom centre, 12 pt above the edge, visible only when a finished picture is on stage (`ImageGenAction.offered`); while painting it holds its room, invisible, so the stage does not change shape.
- **Shelf** — a 112-pt-wide column: the machine's folder merged with this session, thumbnails 88 × 88 aspect-fill, 8-pt gutters, selected tile has a 2-pt accent ring; hover shows the age and size; double-click puts it on stage; right-click shows the same verbs; **drag a tile out** to Finder or another app (file promise of the original bytes); the job in flight leads the shelf as a tile that wears the sketch. In the Video lane the thumbnails are posters with a duration badge. A shelf the machine cannot list (too old, asleep) says so in one line and shows the session's own pictures.
- **Brief dock** — the one floating glass layer. Words box 2 lines tall growing to 6, type role `canvas`, placeholder from `ImageGenStudioWords`; chips are Core's `ImageGenField` list rendered as the same pill buttons the chat composer uses (so the composer lane and the studio can never disagree about what a picture is made from); "Enhance" with the helper picker (`ImageGenHelperFinder`) sits at the words box's trailing edge; the rewrite card (use these words / keep mine / write again / one line to change) slides *up out of the dock* over the stage's lower third, never pushing the stage; the estimate line (`ForgeClock`, `ImageGen` timing) is quiet text at the dock's trailing foot.
- **Start-from slot** — a 56-pt square at the dock's leading edge: a dashed drop target when empty, the picture when held (× to remove, click to replace; Photos/Files/clipboard/the machine's gallery per `ImageGenReferenceSource` — on the Mac: Choose file…, Paste, From the machine's gallery, drag from Finder or from the shelf). In the Video lane the same slot is "Start from" and also accepts *the end of an earlier clip* (Continue it).
- **Machine pill** (toolbar centre) — status dot (breathing only while a job runs; stillness otherwise), machine name, the single most useful fact (`ImageGenDoor.line`: "Quality ready" / "Speed only — Qwen files missing" / "asleep"), disclosure opens the machine sheet (the six model files file by file, version, last check, check again, change machine). Danger tone when it cannot paint.

### 5.3 Details that decide whether it feels right

- **Type**: words in role `canvas`; chips and shelf captions in the chrome roles; numerals tabular wherever they change while watched (elapsed, step, seed). No sizes invented.
- **Colour**: tokens only. The accent marks the selected tile, the primary button and the progress line; `warn` is a stopped-for-you state; `danger` a failure. Nothing is tinted to carry meaning alone.
- **Motion**: stage sketch updates replace the paintable without relayout; the sketch→picture crossfade is 240 ms ease-out, once; the rewrite card rises 160 ms; a job tile is inserted into the shelf by a 160-ms slide; reduced motion makes every one an instant change. The status dot breathes on the shared swell (`ActivityMotion`), only while working.
- **Keyboard** (registered in Core's shortcut registry, shown in the menu): ⌘↩ Generate/Render, ⎋ Stop, ⌘E Enhance, ⌘⇧R Again, ⌘1 / ⌘2 Image / Video lane, ← → walk the shelf, ⌘S Save, ⌘C Copy (when the stage is focused), ⌘⇧E Edit this, Space Preview full size (Quick Look-style viewer = the existing image viewer).
- **Drag and drop**: files/images onto the dock or stage become the start-from/reference (a stage drop reads "Edit this picture"), the shelf accepts nothing (it is the machine's), tiles drag out.
- **Accessibility**: stage has a label stating the state in words (Core's `ImageGenProgress` sentence); every chip is a labelled button with its value; the shelf is a list of pictures with their words as the label; the live sketch is decorative (`isAccessibilityElement = false`); a finished picture posts a polite announcement.
- **Copy** reuses Core's strings; new strings: the lane names, the machine pill's fixed words, the drop-target sentence, the shelf's "Drag out to save" tooltip.
- **Sizes**: dock min height 96 pt (two rows), shelf 112 pt, stage margin 24 pt, tile 88 pt, verbs capsule height 36 pt, toolbar controls at the standard Mac toolbar height. Under 960 pt the shelf folds into a horizontal strip above the dock (88 pt high); under 760 pt the chips fold into one "Settings" popover.

### 5.4 The video lane

Same anatomy with these differences: the stage plays the finished clip inline (AVKit, no chrome until hover, loops muted unless sound exists), the sketch is the machine's low-res frame stream; the progress line is segmented by the graph's passes ("First pass · Second pass") from `ForgeJob`'s own count; chips are Size / Length / Smoothness / Sound / Seed; the start-from slot offers *a picture*, *the machine's gallery*, or *Continue* (the last frame of the clip on stage); the estimate line comes from `ForgeClock` ("about 1 min 15 s at 1280×704 · 5 s").

### 5.5 What changes on the other two clients

The Mac is the template; the phone and Linux keep their idioms but take the same decisions:

- **iOS** — the stage grows to fill the space above the dock and **draws the live sketch** (it already receives frames), the shelf becomes a horizontal strip *above* the dock instead of under the keyboard, the chips row shows value and label (no clipped values), verbs dock under the finished picture, the machine fact line moves into a pill in the nav bar. The three video gaps (Enhance, live sketch, start-from) close with the Mac work because they are the same Core pieces.
- **Linux** — the pane keeps its layout but the shelf moves to the right rail/filmstrip with real thumbnails (no cropped grid), the verbs dock under the stage, and the machine pill replaces the "Renders this pane's GPU work…" note.

## 6. Alternatives considered (mocks in `docs/studio-mocks/`)

- **A — stage + inspector (the form):** a right-hand inspector column carrying words, chips and the Generate button, stage on the left, shelf as a bottom filmstrip. Familiar from tools like Photoshop/Draw Things, but it makes the words box one field among nine, duplicates the chips as a *different* layout from the chat composer's lane, and gives the stage ≈ 62 % of the width.
- **B — stage + brief dock (chosen):** the brief is one sentence at the foot, the same chip row the composer lane uses; the stage takes ≈ 78 % of the width; the shelf is a rail. The words are the largest control; the composer lane in a chat and the Studio are visibly the same thing at two sizes.

B is chosen because it keeps one vocabulary between the chat's image/video lane and the Studio, gives the output the room the first look showed it lacked, and puts the single most important control (the words) where a person's hands already are.

## 7. Risks and open decisions

- A floating glass dock over a stage means picture content passes under glass; the dock must stay legible over any picture (glass material handles it; verified in the mocks over a bright and a dark picture).
- The panel (not sheet) makes "closing leaves the job running" a window-lifetime fact; the existing `ForgeRunner`/`ImageStudio` singletons already own the jobs.
- Thumbnails for 100s of pictures: the library cache (`ImageGenLibraryCache`) already holds listing, facts and thumbnails; the Mac renders from it lazily.
- The Mac Store build is sandboxed: the machine is reached over the network (allowed); dragging out uses file promises (allowed); no new entitlements.

## 8. Mocks, and what looking at them changed

`docs/studio-mocks/` holds self-contained HTML mocks and their renders (open `index.html`): A and B empty / painting / done, B failed, B video running and done, B light and dark, B over a bright picture. Looked at side by side:

- **A** reads as a settings form with a picture beside it: five labelled groups, the words box one of them, a bottom filmstrip with half an empty row, and dead bands above and below a 3:2 picture in a 730-pt column. It confirms the complaint in §2.3, so A is rejected.
- **B** is the design. The stage is 87 % of the window, the words are the largest control, the chip row is the composer's own, the rail is compact and the video lane is the same anatomy with a different dock. Three refinements the mocks demanded, now part of the spec:
  1. **The dock never covers the picture.** The mock let the dock overlap the lower 30–35 pt of a 3:2 picture "so the glass has something to blur"; that hides the footer of every picture it shows. The stage reserves the dock's height and the picture is aspect-fit in what remains. The dock is glass over the canvas, which is still the platform's floating-layer contract.
  2. **The progress line belongs to the stage, not the window.** It is drawn along the bottom edge of the stage rectangle (the sketch's own edge), segmented by the graph's passes in the video lane, rather than under the dock where it detached from the thing it measures.
  3. **The verbs capsule gets a stronger fill** than the dock (regular glass plus the scrim token) because it is the one piece that sits over picture content: over a near-white picture it measured 5.3 : 1 against 16 : 1 for the dock, which is not enough for a control a person must read at a glance.
- Legibility over a bright and a dark picture was checked (dock text ≈ 16 : 1 on both once the dock no longer overlaps the picture and sits on canvas; capsule as above). Light and dark appearances both hold.
- The dock is tall (≈ 124 pt, two rows). On a window under 760 pt tall the second row folds into a "Settings" popover.

## 9. Implementation (after §1–§8)

1. Mac Studio (new): panel, lane switch, stage, shelf, dock, machine sheet, rewrite card, library, live sketch, start-from/continue, verbs, menus + shortcuts, drag in/out. Closes `imageGenSlot` (the slot as a pane on the grid too, hosting the same stage + dock), `imageLane` (composer pills row draws the lane and opens the Studio on it), `imageLibrary`, `imagePromptHelper`, `imageLivePreview`, `videoPromptHelper`, `videoLivePreview`, `videoFirstFrame` on the Mac.
2. iOS: sketch on the stage for image and video, shelf strip above the dock, labelled chips, Enhance, start-from/continue/animate (closes the three iOS video gaps).
3. Linux: shelf rail with thumbnails, verbs docked under the stage, machine pill.
4. Parity manifests honest throughout; strings in all languages; selftests; installed on every desk it touches.
