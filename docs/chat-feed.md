# The chat feed: pictures that open from where they are, and a history you can read back

Asked for on 2026-11-16: make opening and closing media in the chat smooth, then look at the feed as a
whole and make it convenient to consume and to act on. This is the look, the ranking, the design and
the mocks, written before the code. `docs/chat-design.md` stays the contract for the screen; this adds
to it and changes none of its principles (answers still fill the pane, the strip of pictures stays
small, Megatron's card is untouched).

## 1. What was looked at

- **Linux** in the headless harness at 2400 by 1300: three demo conversations, a staged turn with four
  pictures of four shapes, the viewer held at 35 % of its rise and at rest, and two real long
  conversations.
- **Mac**, an isolated debug build: a staged eight-message conversation (a 14-line prompt, six tools, a
  table, code, links, a harness line, a strip of four pictures and a lone one), top and bottom.
- **iPhone 17 Pro Max simulator**: four demo conversations with staged pictures, dark and light.
- **The code**: the three viewers and their hosts, and an inventory of what a press, a long press, a
  hover and a key do to every kind of row on each client (three readers, every claim anchored).

## 2. What is wrong, ranked

1. **A picture does not open; a viewer arrives.** On Linux and the Mac the viewer is the Studio's sheet:
   an opaque dark slab that slides up from the bottom of the window (`StudioSheetMotion`, 28 % of its
   height in 320 ms). The picture that was pressed is not part of the motion at all. On the phone the
   picture does fly, and four things break it: a strip hands the viewer its whole row, so the picture
   springs out of and shrinks back into a wide band (`ChatViewController+CellDelegates.swift:13`,
   `from: cell`); the tile stays in the chat while its copy flies; a picture still decoding has no
   flight and cuts to black (`animateIn` guards on `currentCell?.image`); and a viewer closed on
   another page has no home, so it falls off the screen though its tile is in plain sight. The viewer
   is presented unanimated with an opaque backdrop and only starts its motion in `viewDidAppear`.
2. **The harness speaks in the reader's voice.** When a background command or agent ends, Claude Code
   writes a `<task-notification>` line and starts a turn of its own. claude-bridge condenses it to a
   sentence and sends it as a prompt (`TranscriptIndex.typedText`), so `Background command "Wait for
   the release workflow" completed (exit code 0)` wears the reader's accent bar on the desktops and
   the reader's blue bubble on the phone, and `[` and `]` stop on it. A long agent conversation is
   half of these. Core already has the line it should be (`TranscriptNote.workFinished`, drawn by
   every client); only opencode 2 ever sends it.
3. **A long prompt is the tallest thing in the history.** A 14-line prompt is 266 pt on a desktop and
   more than a whole screen on the phone, in the one voice the reader never needs to read back in
   full. Pastes fold (`PasteFold`); typed and dictated prompts do not.
4. **A picture cannot be acted on in the transcript.** Linux and the Mac give a tile no menu at all:
   copying or saving a picture means opening the viewer. On the phone a lone picture has a menu (Save
   to Photos, Copy, Save to Files, Share) and a strip does not: its long press is the row's menu, whose
   Copy copies the filenames.
5. **Page keys do nothing.** `j`, `k`, `ctrl+d`, `ctrl+u`, `g g`, `G`, `[` and `]` move the transcript;
   Page Up, Page Down, Home and End, the keys a reader's hand already knows, are unbound on all three.

Seen and left alone, with the reason: prose at the full width of a wide pane (decided, `eca9c8b9`);
strip tiles of 56 to 104 pt (decided today, `ec945d03`); a one-tool turn wearing a whole Megatron card
(the card's size is its own design, `neural-trace-readout.md`); disclosures that open without motion
(a rebuild runs per streamed token, and an animated height is a relayout per frame); the Mac's find
not reaching rows above its window, tables with no copy on the desktops and an edit diff that stops at
80 lines (real, smaller, listed in §9).

## 3. Principles added

8. **Media moves; chrome appears.** When something a reader pressed becomes something larger, the thing
   itself travels from where it was to where it will be, and everything around it fades. Nothing that
   was not on screen slides in beside it. It goes back the way it came, to where it lives now.
9. **The feed has two voices and a margin.** The reader's prompt and the agent's answer are the voices.
   Everything a machine wrote on the way (a model change, a restart, work coming back) is a note in the
   margin between turns, never a prompt.
10. **History costs what it is worth.** What the reader wrote and already knows folds; what the agent
    answered does not.
11. **A thing can be acted on where it is.** If the viewer can copy or save a picture, so can its tile.

## 4. A picture opens from where it is

One geometry and one clock in Core, `PictureFlight`, drawn by all three clients.

- **What flies** is the tile's own pixels (the thumbnail the transcript already holds), so a flight
  never waits for a decode. It is drawn filling its frame (aspect fill). The frame goes from the
  tile's rectangle to the rectangle the viewer fits the picture into; as the frame's shape approaches
  the picture's own, the fill stops cropping, so the square crop of a strip tile opens into the whole
  picture and the last frame is exactly what the viewer draws. A lone picture, fitted inside its tile,
  starts from the rectangle its pixels cover, not from the tile's letterbox.
- **Corners** go from the tile's radius (`ChatChrome` control, 10) to the viewer's (0).
- **The tile left behind is not drawn** while its picture is out: from the first frame of the flight
  until the viewer has closed or turned to another page. Nothing in the transcript moves.
- **Around it**: the backdrop (the phone's black, the desktops' scrim and the viewer's slab) is fully
  in by 45 % of the flight; the viewer's words and buttons fade in over the last 45 %. On the way
  home the words are gone in the first 30 % and the backdrop lifts from 15 % on, so the reader sees
  where the picture is going while it goes.
- **Home is where the picture lives now.** Closing asks the transcript for the tile of the page being
  shown, not the one that was opened. A picture the strip only counts in its corner chip has no tile
  and so no home. A picture with no home, or whose tile is less than half in sight, fades where it
  stands in 160 ms (the phone also draws it 4 % smaller); on the phone one that was thrown keeps the
  finger's direction as it fades, as today.
- **Clock**: 280 ms out of the tile on an ease-out cubic, 220 ms home on an ease-in-out cubic, on the
  desktops; the phone keeps its spring (420 ms, damping 0.86) and, when a drag lets go, starts the
  spring at the finger's speed. Reduced motion: no travel, a 120 ms cross-fade of the whole viewer.
- **The sheet on the desktops** keeps everything it is (its frame, scrim, focus trap, keys, stack). It
  gains a second way to arrive: *in place*, by opacity, when the viewer is opened with an origin. With
  no origin (the Studio's shelf, a driver) it rises as it always has.
- **Paging inside the viewer** is unchanged.

## 5. The harness is not the reader

claude-bridge keeps sending the sentence it sends today, for clients that know no better, and adds
beside it what the line is: `notice: { work: command | agent, outcome: completed | failed | stopped,
title }`. The Kit turns a message that carries a notice into the note it already models
(`.workFinished`), and the three clients draw it with `TranscriptNoteReading` as they draw every other
note: one quiet line between the turns, `✓ Background command finished: Wait for the release
workflow`. Nothing about the turn that follows changes. `[` and `]` step over it because they step
between prompts and it is no longer one. An older bridge sends no notice and reads as it does today.

## 6. A long prompt folds

`PromptFold` in Core decides from the words and the width they are drawn at (the client says how many
characters fit a line): a prompt that would run past **ten** lines shows about **seven**, ends on an
ellipsis, and carries a fold line (`Show more`, `Show less`). Core also cuts the words
(`PromptFold.cut`): a toolkit's own line limit counts each paragraph apart on GTK, which let a listed
prompt through whole, so every client draws the same cut and none depends on how its labels truncate.
Linux sets prompts in a face where every character is as wide as the next, so its seven lines are
seven; the phone and the Mac estimate from the type's size and land within a line of it. Opening is in
place and is remembered for the life of the pane beside the other expansions (`TranscriptExpansion`,
key `prompt:<message id>`). The prompt being answered now folds too. The whole prompt is still what
Copy copies and what find matches.

## 7. A picture can be acted on where it is

One set of verbs, named once in Core (`PictureVerbs`), on a lone picture and on every strip tile.

- Linux and the Mac, right click on a tile: **Open**, **Copy image**, **Save to Downloads**, **Copy
  path** (the path on the machine that made it, which is what an agent is told). The viewer's own
  Copy and Save are the same code (`PictureDesk`), so the two can never say different things.
- The phone, long press on a strip tile: the tile under the finger lifts and offers what a lone picture
  offers (**Save to Photos**, **Copy**, **Save to Files**, **Share**), titled with its filename. The
  row's own menu no longer answers for a strip, so Copy never means filenames.

## 8. Page keys

Page Down and Page Up are second defaults of the half-page moves (`scroll.halfDown`, `scroll.halfUp`),
Home and End of the top and the bottom of the conversation, in `Shortcuts`, in the conversation's
normal context, on all three clients. Half a page, because a reader paging through an answer keeps the
line they were on in sight. They are ordinary registry entries: listed in the cheat sheet, rebindable
where a client has the editor. The phone's hardware-key table gains the four keys it did not know.

## 9. Not in this pass

Tables with a copy of their own on the desktops; an edit diff past 80 lines that can be opened in full;
the Mac's find walking rows above its window; a flight for the Studio's own pictures and for clips; a
motion for paging inside the viewer.

## 10. Alternatives considered

- **Make the sheet's rise shorter and softer.** Cheaper, and still a viewer arriving rather than a
  picture opening; the phone would stay the only client where the picture moves.
- **A zoom of the whole sheet out of the tile** (scale the slab from the tile's rectangle). The toolbar
  and its words would be drawn at a tenth of their size on the way, which reads as a glitch, and GTK
  cannot scale a widget tree without a snapshot.
- **Hide harness lines altogether.** The turn that follows would have no reason on the page; a note is
  the reason, quietly.
- **Recognise the sentence in the clients.** The sentence is the CLI's English and changes with it; the
  bridge holds the line itself and knows what it is.
- **Fold a prompt by counting its lines after layout.** Exact, and three toolkits each need a second
  layout pass per prompt on a path that runs per streamed token. An estimate decides; the toolkit's own
  line limit draws.
- **Fold every prompt but the newest.** The newest then folds the moment a second one is sent, moving
  the transcript under a reader. One rule for all of them moves nothing.

## 11. Mocks, and what looking at them changed

`docs/chat-feed-mocks/`: `flight-desktop`, `flight-phone`, `prompt-fold`, `notice`, `picture-menu`,
each dark and light, as HTML and the PNG rendered from it.

- **Two layers of words were read through each other.** In the first desktop storyboard the viewer's
  toolbar faded in over the transcript at the same rate as the scrim, and at 180 ms the file's name
  sat on top of the prompt at 60 %. The backdrop now finishes by 45 % and the words start at 55 %.
- **The flying picture's shadow outlived the flight.** It read as a card on the first frames and as a
  mistake at rest, where the viewer draws none. Dropped: the scrim separates it.
- **A fade over the last line of a folded prompt made that line unreadable** and needs a gradient over
  selectable text on three toolkits. An ellipsis says the same and is the toolkit's own.
- **"Show all 14 lines" lied on the phone**, where fourteen written lines are twenty-five drawn ones.
  The fold line says `Show more` and `Show less`.
- **The fold control in the accent colour read as a link in the prompt.** It is the quiet fold line
  code blocks have.
- **A note on the phone wraps to two lines** where the desktops fit one; it keeps its glyph on the
  first line and is not centred there.
- **The closing storyboard showed the lighthouse going back to the lake's tile** in a first sketch of
  the rule; that is what made "home is where the picture lives now" a rule rather than a detail.
- **Linux tiles were square.** The contract says small rounded squares and the Mac and the phone
  draw them so; GTK's button was not clipping its picture. The flight's corners start from 6 there
  now that the tile has them (seen in the first harness frames, and fixed with the flight).
- **GTK's line limit is per paragraph.** The first folded prompt on Linux showed all twenty lines
  under a fold line that said Show more. Core cuts the words instead (§6).
- **Running the ramps backwards hid the way home.** With the backdrop held until the last 45 %, the
  picture shrank over black and the chat appeared only as it landed. The words now go first and the
  backdrop lifts across the rest (found building the phone's close, and redrawn here).

## 12. Risks and measures

- **A flight that ends a pixel off pops.** The last frame of the flight and the viewer's page must be
  the same rectangle: both come from one function (`PictureFlight.stage`), and each client's selftest
  compares them.
- **GTK cannot animate a widget's size without a relayout per frame.** The flight is one paint widget
  over the window that draws the texture at the frame Core gives it on the frame clock; no widget is
  resized.
- **The Mac's `--shot` is offscreen.** The flight is checked with the sheet's own hold (`viewerat`) and
  the flight's (`flightat`), which freeze both at a progress, and the frames are read from pictures.
- **A fold that opens nothing.** The estimate folds past ten lines and the limit draws seven, so the
  estimate would have to be wrong by a third for the control to be dead; Core's tests pin the rule
  at phone and desktop widths.
- **An old client on a new bridge, a new client on an old bridge.** The notice rides beside the
  sentence; either side missing it reads as today.
- **Acceptance**: on each client, pictures of the flight at 0, 30, 65 and 100 % out and at 45 % home
  from another page; the staged conversation's first screen showing the answer under a folded prompt;
  a harness line drawn as a note; a menu on a tile; the page keys moving the transcript.

## 13. Implementation

1. Core: `PictureFlight`, `PromptFold`, `PictureVerbs`, the four page-key defaults, tests; the parity
   cases `pictureFlight`, `promptFold` and `pictureActions`.
2. claude-bridge: the notice beside the sentence, tests, a tagged release. Kit: the notice read into a
   note, a note that reports work back ending the answer before it as a prompt does
   (`ChatMessage.reportsWorkBack`), a tag, both pins.
3. iPhone, Linux and the Mac: the flight, the fold, the menus, the keys; staging hooks and selftests;
   pictures read at every step above.
4. Parity manifests honest; Linux installed; iPhone and Mac as internal TestFlight builds.
