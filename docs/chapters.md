# Chapters — how a long chat got where it is

Asked for: "As the session continues on and on and the title changes over time, it would be nice to have a way to coherently understand the evolution at a high level that's easy to digest." Same order as the other design docs: **look** (§1), **design** (§2–§5), mocks in `docs/chapters-mocks/`, then **implement** (§7).

## 1. What I looked at

- **claude-bridge renames a chat as its topic moves, and throws the old name away.** After the first finished turn `Titler.title` replaces the prompt-derived title; then every third message of the person's (`retitleEvery`) `Titler.revised` is shown the title and the newest exchange and answers `KEEP` or a new title. `Session.title` is one string, overwritten in place. Nothing anywhere (bridge, Kit, Core, clients) keeps an earlier title.
- **Only claude-bridge re-titles.** opencode 1.x and 2.x name a session once, from its first message, and only rename on request (`session.renamed` carries no source and no history). omp-bridge titled once (`autoTitled` blocked every later call) until 0.13.0, which keeps chapters too (§ 8). The server is the only party that sees every rename: a client sees a title only while it lists sessions.
- **The open chat learns its title only from the list.** `TranscriptSnapshot` carries no title; iOS polls `listAllSessions` at 0, 12 and 40 s after a turn; the desktops adopt `list.upsert`. A device that was asleep for a rename never sees it.
- **The bridge's turn number is the count of `.user` messages in `session.messages`**, the same array `GET /sessions/:id` serves, and store-minted message ids survive the fold (`SessionStore.named`). A boundary can be named by message id with the turn as a fallback.
- **Nothing in the transcript says the topic moved.** The model seam (`ModelSeamTracker`) and the compaction seam are the only dividers. iOS's overflow menu has "Jump to message" (the last 20 prompts); the desktops have `[`/`]` prompt jumps. Neither says what any stretch was about.

## 2. Design

One noun, **chapter**: a stretch of the conversation under one title. A chapter begins where the bridge decided the topic had moved. Renames inside a stretch — the prompt-derived title replaced by the first model title, a person's rename, an agent's own title — rename the chapter, they do not start one.

| Piece | Where | Shown when |
|---|---|---|
| **Chapter heading** | transcript, above the person's message that opened chapter n | 2+ chapters |
| **Chapters panel** | iPhone sheet, Mac popover, Linux panel | opened from the chip or band fact, a heading, the menu, `g c` |
| **Chapters fact** | facts row (iOS) / band (desktops): `📖 3 chapters` | 2+ chapters |

A chat with one chapter draws nothing new (mock 3). Nothing is drawn for opencode, whose server keeps no chapters.

### The heading

Left-aligned under the turn's own rule, `§ CHAPTER 3 · 16:10` in the seam label role, the chapter's title under it in the card title role, wrapping as far as it needs rather than truncating. On iOS it is a `.header` (and a button), on the Mac an `AXHeading` that can be pressed, so the headings rotor walks the chapters; GTK 4 has no per-widget heading role, so on Linux it is a button whose label says "Chapter 3: title". Pressing it opens the panel on that chapter. Chapter 1 gets a heading at the top of the transcript once a second chapter exists — unless its name was kept from before chapters were, because that name may say what the conversation became rather than how it began. A heading that lands above the row a reader who scrolled up is reading keeps that row where it was on screen (iOS holds the reading place across the apply).

### The panel

```
Chapters                                   Done
3 chapters over 17 turns · since 13:05
[▬▬▬▬▬▬▬▬|▬▬▬▬▬▬▬▬|▬▬▬▬▬▬]   ← share of turns, the current one lit

①  Fix stream freeze on resume
    Traced the freeze to URLSession hanging on a 401 and shipped Kit 0.42.3.
    Turns 1–6 · 13:05–15:10
②  Bridge restarts wait for quiet
    Restarts now wait for a quiet machine; released claude-bridge 1.21.0.
    Turns 7–12 · 15:15–16:02
③  Chat title history as chapters                    NOW
    Turns 13–17 · since 16:10
    Named by you
```

- **Gist**: one sentence, written by the bridge when the chapter closes (the next one opens), saying what that stretch got done or decided. The open chapter has none: it has not come to anything yet.
- **Span**: turns and wall-clock times, never a duration — a chapter left overnight would read "14 h".
- **Who named it**, only when it was not the model: you, the agent, its schedule, a fork, or "Named before chapters were kept" for a conversation older than this feature.
- A row jumps to where the chapter began and closes the panel; the strip is a picture only (hidden from assistive technology, the rows say the same). The current chapter is lit and the panel opens scrolled to it (or to the chapter a heading named) with the keyboard on it: ↑ ↓ (Mac), Tab (Linux), Return, Esc.
- A jump to a chapter that began above the rows a desktop pane draws widens the message tail and the row window to it and lands once those rows are drawn — the Mac's rows fill in chunks, so the jump waits for the fill — and the Mac narrows the window again once the reader is back at the bottom.
- The panel reads again when the chapters change or the conversation gains a message while it is up, keeping the focused row and the scroll place.

## 3. Wire contract (claude-bridge 1.22.0)

`Session.chapters: [Chapter]?` — stored with the session, served by `GET /sessions/:id`, `POST /sessions`, fork; never on `SessionSummary` (list rows stay small). Absent means "this server keeps none". Added to, never renamed.

```json
{ "title": "Bridge restarts wait for quiet", "turn": 7, "messageID": "8F3C…",
  "startedAt": "2026-11-09T15:15:02Z", "gist": "Restarts now wait…", "namedBy": "model" }
```

`namedBy`: `prompt`, `model`, `person`, `agent`, `schedule`, `fork`, `kept`; a client reads an unknown word as `model`.

`BridgeEvent.chapters([Chapter])` (`{"type":"chapters","chapters":[…]}`) on the session stream and inside `/stream`'s `session` frame, always the whole list, whenever it changes. A client that missed one is right again at the next frame or transcript read.

Rules, in `SessionStore`:

| Event | Chapters |
|---|---|
| first prompt recorded (or the first after `/clear`) | chapter 1 opens at turn 1, named by `prompt` (`person` when `customTitle`, `schedule` for a schedule) |
| first model title | chapter 1 (the current one) renamed, `model` |
| revision says the topic moved | a new chapter opens at the message the model names (below), `model`; the closed one gets its gist |
| revision says KEEP | nothing |
| rename (PATCH title) | current chapter renamed, `person` |
| ACP agent title | current chapter renamed, `agent` |
| fork | chapters copied; the last renamed "Fork of …", `fork`; the fork's first model title reads that chapter's opening exchange |
| `/clear` | chapters dropped (the transcript is gone) |
| any title event on a conversation with history but no chapters | chapter 1 is first written from the title it had, at turn 1, `kept` |
| a conversation with 6+ of the person's messages and no chapters is read (`GET /sessions/:id`, 1.23.0) | its history is split once: the person's messages, numbered (notices out, thinned evenly to 150), go to the titler, which answers `n \| title \| what it came to` per chapter; the last keeps the chat's own name; a chat that gained chapters meanwhile keeps its own |

**Where a chapter begins.** The revision is shown the person's messages since the last look (up to four, numbered) and the newest answer, and answers `KEEP` or `n: new title`, `n` the message where the new topic began. A bare title (no number) begins at the newest message. The boundary never moves at or before the previous chapter's start.

**The gist.** One `haiku` call per closed chapter (rare: only when the topic moves): the title, the person's messages in the chapter (each cut to 240 characters, at most the first and last seven), its last answer (600), asking for one past-tense sentence of at most 16 words. A failure leaves the gist empty; nothing retries.

opencode keeps no chapters and is not changed; the Kit reads their absence as `nil`. omp-bridge 0.13.0 serves the same wire (§ 8).

## 4. Kit (0.51.0)

- `ConversationChapter` (AgentCore): `title`, `turn`, `messageID?`, `startedAt`, `gist?`, `namedBy: ChapterNamer` (unknown words → `.model`).
- `TranscriptSnapshot.chapters: [ConversationChapter]?`, filled by `ClaudeCodeBackend.transcript` from `BRSession.chapters`.
- `BackendEvent.chapters([ConversationChapter])`, decoded by `BridgeEventDecoder`.
- `ConversationState.chapters: [ConversationChapter]` (empty when none), adopted from every transcript read and every frame — whichever is newer wins by being last, both being whole lists.
- `MockBackend` takes `chapters:` so demos and selftests can draw them.

## 5. Core

- `ChapterReading` (`Chapters.swift`): from the chapters, the messages and a clock → `isShown` (2+), the header words, the strip shares, and one `ChapterLine` per chapter (number, title, gist, span words, who-named-it words, `anchorID`, `isCurrent`). The anchor is the chapter's `messageID` when the transcript holds it, else the person's `turn`-th message, else the first message.
- `ChapterHeadingTracker`: `[messageID: ChapterHeading]` keyed by the message a heading goes above. Incremental like `ModelSeamTracker`: it keeps the person's message ids as it walks settled messages, so a streamed token costs nothing and a new chapter list costs one dictionary rebuild.
- `StatusFacts.chapters` → band segment `chapters` (`📖 3 chapters`, quiet, `.act(.chapters)`), the last segment, so it yields first.
- `AppCapability.chapters` with its spec; `ShortcutRegistry`: `chat.chapters` ("How this chat got here") → `KeyAction.showChapters`, `g c` in normal mode on every desk (iPad with a keyboard included); the Mac's Chat menu has Chapters… wearing whatever the registry binds, and the ⋯ menus on all three have Chapters… with the count.
- The strip keeps every piece at least `stripFloor` of its width after the shares are made to sum to one (`ChapterReading.floored`).

## 6. Mocks, and what looking at them changed

`docs/chapters-mocks/phone.png` (+ `-light`), `desktop.png` (+ `-light`); `render.sh` renders them headless.

- **The divider became a heading.** The first mock centred `── 📖 CHAPTER 3 · Chat title history as ch… ›──` between rules like the compaction seam: on a phone the title, the one thing worth reading, was what got cut. A left-aligned heading with the title on its own line keeps the whole title, wraps instead of truncating, and is a real heading to VoiceOver.
- **No chevron on the title.** A `⌄` after the nav title took room from the title it decorates and truncated it. The title still opens the panel on a tap; the discoverable door is the facts chip.
- **Times, not durations.** "2 h 10 min" for a chapter that spanned lunch read as effort; `13:05–15:10` reads as what it is.

## Review, and what it changed

Before building, three critics read this doc against the code; after, a reviewer per client looked for bugs, each finding checked by two refuters. What they changed:

- **A reword is not a move.** The first revision prompt answered KEEP or a new title, and a bare new title opened a chapter, so every rephrasing would have. The look now answers `KEEP`, `RENAME: title` or `MOVED n: title`; a bare title is a rename, and only MOVED opens a chapter.
- **A failure is not a KEEP**, one look per conversation is out at a time, an older look never lands over a newer, a first title written for a conversation a clear emptied is dropped, and chapters carry a revision so a slow read never undoes a newer list.
- **A person's rename pins the title but not the chapters**; an ACP agent that names its own chat is no longer renamed by the bridge every turn.
- **Measured on real conversations** (two of the bridge's own, 45 and 40 turns): the first prompt ("Prefer KEEP…") opened 0 and 1 chapters where a reader sees four or five phases; "the focus has shifted to a new task, problem or phase of the work … a single side question is not a shift" opened 1–2 at the right turns (35: "Parallelize RTX Pro 6000 benchmark suite", 6: "Stream Desktop Display to Tablet"). Chapters are coarse phases, which is the digest asked for.
- **Clients:** the Mac jump that did nothing far up a long chat (rows fill in chunks), the window a jump left wide for the rest of the session, focus lost when the panel re-read, spans gone stale while turns arrived, a pending jump that outlived a chat switch, a chip that refreshed every render after its chapters went, a ring colour that missed a dark-mode switch, and the strip floor broken by normalising.

## 7. Implement

1. claude-bridge 1.22.0: `Chapter`, the rules above, `Titler.revised` with a boundary, `Titler.gist`, `BridgeEvent.chapters`, tests; tag.
2. Kit 0.51.0: model, decode, event, state, mock; tests; tag; bump `Kit.version` in TailscodeCore and TailscodeLinux.
3. Core: `ChapterReading`, `ChapterHeadingTracker`, band segment, capability, shortcut, strings; tests.
4. iOS, Mac, Linux: heading row, panel, fact, entry points, jump; selftests and screenshots of each.
5. Ship: Linux install, iPhone and Mac TestFlight.

## 8. omp-bridge (0.13.0)

The same wire, rules and verdict grammar as claude-bridge, in omp-bridge's own `Chapters.swift` and `Titler`. What differs:

- **A chapter is kept by turn, not message id.** oh-my-pi's transcript names a message `u-<entry id>` while the live turn that wrote it was `u-<random>`, so a stored id is wrong after any restart. The store keeps `turn` and `startedAt`; every read and frame works `messageID` out again from the turn (`ChapterBook.resolved`).
- **Reading the transcript back recounts.** A slash command oh-my-pi answers itself is a message live and none on disk, so turn numbers can shift. `ChapterBook.reanchored` moves each chapter to the person's message nearest when it began (within 30 s) and never at or before the chapter ahead of it; a gist finds its chapter by `startedAt`.
- **The looks run on the chat's own engine** (`omp -p --no-session --no-tools --thinking off`, or `OMP_TITLE_MODEL`), which is often a local model: every answer is read past `<think>…</think>` and markdown, taking the last line in one of the three shapes. A split may take 240 s.
- **A split is checked before it is believed.** Measured on real omp chats of 33–42 messages with local engines: Nemotron Bolt opened a chapter at every message, and Pennyroyal numbered its chapters 1, 2, 3 where it was asked for the message each began at, or gave 13–14 fine-grained ones. The prompt now states the cap and says the number is the message's own (a chapter that began at message 12 starts its line with 12), after which Pennyroyal split the same chats into 8 and 11 chapters at the right messages. An answer with more chapters than half the messages, or numbered 1, 2, 3, is no answer and the next engine is asked; one finer than the cap (one chapter per three messages, at most 12) has its shortest chapters after the first folded into the ones before them.
- **`/clear`** empties the chapters with a frame, and the next exchange is named afresh (`autoTitled` resets), as on claude-bridge.

