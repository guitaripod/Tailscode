# The box: writing to an agent on a phone

Asked for on 2026-11-21: make input on the iPhone and iPad extraordinary. This is the look, the
ranking, the design and the mocks, written before the code, and then what building and looking at
the real thing changed. `docs/chat-design.md` stays the contract for the screen and
`docs/dictation.md` for speaking into the box; this adds to both and changes neither.

## 1. What was looked at

- **The composer on an iPhone Air simulator (iOS 27.3), dark**, in the demo world: empty over a
  running turn, the slash list open, a twelve-line draft, a folded paste beside the box, and a
  hands-free dictation take.
- **The code**: `ComposerView` (the glass box: the plus, the words, a row with the model dial, the
  microphone and Send), the strip of chips above it, `SlashCommandPalette`, the dictation
  controller, Home's `HomeComposerBar`, and what each server can list of its own disk.
- **What the others ship in 2026**: the chat apps (a plus sheet, a box that expands to a full-screen
  editor, voice) and the coding agents (an `@` that finds a file, a slash list, a model picker in
  the box, queued messages).

## 2. What is wrong, ranked

1. **A long prompt has six lines and a guillotine.** The box stops at 132 pt and cuts the words
   through the middle of a line at its top edge. A twelve-line prompt, which is an ordinary one
   here, shows half of itself, with nothing to say there is more and no way to see the whole. The
   transcript above keeps half the screen while the thing being written has a sixth of it.
2. **The box cannot find a file.** Every agent this app talks to reads `@path` as "this file", and
   a phone is the worst place to type a path. The server can already list its folders; nothing in
   the box asks it to.
3. **The box does not know what it holds.** `/compact` and `/compcat` look the same until one of
   them is sent as an ordinary message. A path, a name in backticks and the word that summons
   ultracode are all the same ink as the sentence around them.
4. **One arrow for three acts.** Send wears the same up-arrow to send, to queue behind a running
   turn, and to save the rewrite of a waiting message; while a waiting message is open and the box
   was emptied it wears Stop, and a press takes the message back instead.
5. **Everything is two keyboards away.** The slash and the `@` are behind `123`; the backtick is
   behind `123` and `#+=`. A prompt to a coding agent is full of all three.
6. **Things appear instead of arriving.** A line is added and the box is taller on the next frame. A
   pasted picture is a chip that was not there and then is, announced by a toast that says what the
   chip already says.
7. **The chat's attach menu is shorter than Home's.** Home can take a photo; a chat cannot.

## 3. Principles

1. **The box is as tall as the words, and the page is one pull away.** Six lines at rest is what a
   box may take from the conversation without being asked. More is the person's to take.
2. **The box reads what is written, and only what it is sure of.** Ink for a command it would run,
   a path, closed code and the power word. Everything else stays words.
3. **`@` finds the file, and the model is not asked.** The app lists the machine's folders itself.
4. **Send says what it will do.** One button; its glyph is the verb.
5. **An empty box shows its two keys.** The slash and the `@`, one press each, gone with the first
   character.
6. **Things arrive with weight, and nothing is said twice.** A line, a chip and a send each ride
   a spring; a chip that landed is the whole of the news.
7. **Stillness means settled.** Nothing here moves on its own: every motion answers a touch or a
   keystroke, and reduced motion lands each of them at once.

## 4. The design

### 4.1 Room to write (`ComposerLift`)

| State | The box | The handle |
|---|---|---|
| **Rest** | As tall as the words, one to six lines | absent |
| **Rest, more than six lines** | Six lines; the words scroll and fade into whichever edge they run past (20 pt above, 14 pt below) | a 36 × 4.5 pt pill on the top edge |
| **Held** | Follows the finger between six lines and the ceiling; gives softly past either end (36 pt of slack) | under the finger |
| **Lifted** | As tall as the words need, at most to under the bar and whatever floats above the box | stays, so the box can come down |

- The ceiling is the smaller of what the words need and the room the window has
  (`ComposerLift.ceiling`): a fifteen-line prompt lifts to fifteen lines, not to a page of empty
  glass. The room is asked of the screen only while the box is up (`composerRoom`): from the box's
  bottom edge to 28 pt under the navigation bar, which is how far the bar's soft edge still dims
  what passes beneath it, less the chips above the box at the height they stood at rest (never
  the height they have, or a box that took too much squeezes them and is told it has room to
  spare), less 196 pt while a list is up over the box, so `@` in a full page still finds a file.
- A pull that starts on the box's top edge and goes the way the box can still move is the handle's;
  anything else is the words being scrolled. A press on the pill toggles. The edge reaches 14 pt
  above the box and 30 pt into it: a thumb aims at the pill and lands around it, and the chips that
  float just above the box have touch room of their own that comes down to the edge. What decides
  is where the finger came down, not where it is by the time the pull is recognised.
- Letting go settles to the nearer end, or the way a flick was going (`settlesLifted`, 320 pt/s).
- **The conversation does not move, it recedes.** The transcript keeps the room it had at rest
  and the box rises over it (`ComposerView.liftExtra`), so nothing is laid out again per frame of
  a pull; a veil of the canvas comes up behind the box as it rises (full at 96 pt of lift) so the
  chips floating above it are not read against the transcript. A press on the veil lets the box
  down.
- The box comes down on a send (on the same spring the prompt rises on), when the words no longer
  need the room, and when the keyboard is put away, which is how someone says they want to read.
- Every change of height rides one spring (`ComposerLift.response` 0.34 s, damping 0.86), a line
  arriving included. The chips and the transcript's end move on the same beat.
- Feel: `selection` when the handle is taken, `notch` when the box locks into either end.

### 4.2 Ink (`DraftInk`)

| What | When it is inked | How |
|---|---|---|
| A command | The draft opens with a slash and sending it would run something (`SlashDispatch.decide` is not `plainText`) | accent, bold |
| A file | A word that opens with `@` and is a path: it has a folder, an extension, or is on the shelf | accent |
| Code | Between closed backticks on one line, or inside a closed fence | the mono face on a faint plate, as the transcript shows it |
| The power word | `ultracode` as a word, any case | bold, the aura's rainbow a letter at a time |

Code wins over anything written inside it. Nothing is repainted while an input method is composing
or a dictated take is being heard (the take lights its own words). New letters are always written
in ordinary ink, whatever the caret is standing after. Only attributes change, never the words.

### 4.3 `@` finds the file (`MentionToken`, `MentionShelf`, `MentionCrawl`)

- **`@` alone**: *In this change* (up to six files the working tree has changed, from the git
  reading the chat already takes), then *Files* (the project's top folder, folders first).
- **Letters**: matched loosely against the name of every file read so far (`FuzzyRank`, the same
  five tiers as the slash list), best match first, a changed file ahead of an unchanged one, the
  shallower ahead of the deeper. The matched letters are shown; the folder is the second line.
- **A slash**: walks one folder like a shell. Choosing a folder writes `@path/` and stays open.
- **Choosing a file** writes `@path` and a space, quoted when the path holds one.
- **Where the files come from**: `FileBrowsingBackend.listFiles`, which every server already
  answers. The folder the person typed into is read first; then the app walks outward from the
  root four folders at a time, only while the list is open, to 64 folders, five levels and 6,000
  entries, skipping hidden folders, build output and bundles. A walk older than 45 s is read again
  the next time the list opens.
- **When there is nothing**: a folder being read says *Looking…*; letters that find nothing leave
  the list out of the way, because `@MainActor` is not a file; a path from the machine's root or
  the home folder is not this project's to complete. Return on a hardware keyboard sends unless a
  row was chosen.
- A chat with no project, or a server that cannot list, has no list and no `@` key.

### 4.4 Send's faces (`SendFace`)

| Face | When | Glyph | Fill |
|---|---|---|---|
| idle | nothing to send, nothing running | `arrow.up` | the rule colour |
| send | words, nothing running | `arrow.up` | accent |
| queue | words, a turn running | `arrow.up.to.line` | accent |
| stop | no words, a turn running | `stop.fill` | danger |
| save | a waiting message is open for rewriting | `checkmark` | accent |
| take back | that box was emptied | `arrow.uturn.backward` | the rule colour, ink glyph |

A change of verb replaces the glyph in place (`.replace.downUp`). The plate springs from 0.84 as
the box gains its first words, presses to 0.9, and on a send the arrow leaves through the top of
the plate while the next face rises in from under it. The plate and the glyph move, never the
button: a held dictation take already scales the button from outside.

### 4.5 The two keys, the verbs and the menu

- **Keys**: `/` and `@` at the end of an empty box's first line, 30 × 26 pt, outlined, in the mono
  face. Shown only where the box has a line to itself (the stacked box of a chat) and not while a
  take is being heard.
- **A selection's menu** gains *Code* (backticks, or a fence across lines) and *Quote* after the
  system's cut, copy and paste. Each undoes itself.
- **An empty box's menu** gains *Last prompt*: the transcript's newest prompt, back in the box.
- **The plus** gains *Take Photo* (first, where the model can see) and the system's *Scan Text*.

### 4.6 Arrival

A chip that has just been clipped grows into its place from 0.6 on a spring. The three toasts that
repeated it ("…it'll be sent with your next message") are gone; a screen reader is told in words.
Refusals, limits and a paste that became a file still say so.

### 4.7 Home's box

Home's composer is its own view with its own glass button. It takes what is the same act there:
the ink (code, a path, the power word), a line arriving on the spring, and the fade at the edge.
The handle, the keys and Send's faces stay the chat's: Home's box starts a conversation, has no
turn to queue behind and no project listed yet.

## 5. Mocks, and what looking at them changed

`docs/input-mocks/input-dark.png`, `input-light.png` (generated; the HTML is beside them).

- **The handle needs no room of its own.** It was going to push the words down 5 pt when it
  appeared. Drawn, it sits inside the 11 pt the box already has above its first line, over words
  that are fading anyway.
- **The lifted box is not a page.** The first sketch filled the screen. A box as tall as its words
  reads as the same box, grown; a full-screen editor reads as somewhere else.
- **Queue is the send arrow held at a line.** The mock used the system's "play last" list; on the
  real plate at 15 pt it is four bars and reads as a menu button. The arrow that stops at a line
  keeps Send's own arrow and adds the one stroke that says it will wait. Twenty candidates were
  rendered from the real symbol set before choosing.
- **Keys, not a toolbar.** A row of symbols above the keyboard was drawn and dropped: it is chrome
  on every keystroke for three characters. Two keys in the one place that is empty are free.
- **Unknown stays plain.** Drawing `@MainActor` in the accent next to a real path made both look
  like guesses.

## 6. What building it changed

- **A lifted box needed the conversation to recede.** Chips floating over a code block read as
  clutter in the first real screenshot; the veil came from that.
- **The handle is judged where the finger came down.** By the time a pull is a pull the finger
  has moved ten points, which put every pull that started on the pill outside the edge. And the
  pull is heard by the screen, not the box, with first claim over the scrolling of the chips and
  the words, or a pull that began a few points high was the chips' row scrolling.
- **A list that fades out must not swallow the rows that arrive while it fades.** Letters that
  found nothing hid the list, a folder landed 100 ms later with a match, and the fade's end hid
  it again. Whether the list is wanted is now kept apart from whether it is drawn.
- **A chip has to be laid out before it can grow.** The first landing animated a 240 pt picture
  in from nowhere.
- **"No file matches" was noise.** Every path that is not in the project said so while it was
  typed. The list now only ever shows rows, or that it is looking.
- **The power word was a spelling mistake.** The system underlined it in red under its rainbow;
  it is taught to the spelling check once.
- **A full page at the largest type sizes pushed the chips under the bar.** The room was measured
  from chips the box had already squeezed, and stopped 8 pt under a bar whose edge dims 28.

## 7. Where it lives

- **Core** (shared, tested in `ComposerInputTests`): `DraftInk`, `MentionToken`, `MentionShelf`,
  `MentionCrawl`, `ComposerLift`, `SendFace`, `DraftVerbs`.
- **iPhone and iPad**: `ComposerView` (lift, fade, spring, keys, menu), `ComposerSendButton`,
  `ComposerInk`, `ComposerLiftViews`, `MentionFinder`, `ChatViewController+Mentions`, the files
  mode of `SlashCommandPalette`, and Home's `HomeComposerBar` for the ink, the spring and the fade.
- **Parity**: seven capabilities (`composerRoom`, `draftInk`, `fileMention`, `sendFace`,
  `draftVerbs`, `promptRecall`, `composerDoors`). The desks answer ink, the file list and the last
  prompt as gaps, Send's faces as partial, and the handle, the verbs and the keys as not
  applicable, each with its reason.

## 8. How it is checked

`TAILSCODE_COMPOSE` walks the composer with no finger, steps split on `;`: `draft:<words>`, `long`,
`lift`, `drop`, `at:<letters>`, `pick:<n>`, `code:<at>:<length>`, `quote:<at>:<length>`, `attach`,
`last`, `send`, `focus`, `blur`, `clear`, `wait:<seconds>`, `type:<words>` (a letter at a time, `|`
for a new line) and `rewrite` (opens the last waiting message in the box; send into `demo-c1`
first, where a message queues forever). Stills are read from `xcrun simctl io screenshot`; motion
from `recordVideo` cut to 30 fps frames. The handle, the keys, the rows of the file list and the
selection menu are pressed with real touches (`axe tap`, `axe drag`): a pull has to start on the
pill, which sits 7 pt under the box's top edge.
