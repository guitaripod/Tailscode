# The session list

The chat list on all three clients: the Mac and Linux sidebars and the phone's Chats list. Written 2026-11-14 from a screenshot of the Mac sidebar holding 1,800 chats in which nothing told a read chat from an unread one.

Mocks: `docs/session-list-mocks/` (`HEIGHT=1150 ./render.sh desktop.html 'desktop.html#light' 'desktop.html#linux'`, `WIDTH=700 HEIGHT=800 ./render.sh rows.html`, `WIDTH=980 HEIGHT=800 ./render.sh ladder.html`, `WIDTH=820 HEIGHT=1260 ./render.sh phone.html`). `app-mac.png`, `app-linux.png` and `app-iphone.png` are the shipped clients drawing `ChatListFixture`, one of every row: `TailscodeMac --demo --open chat-list --shot <png>` (`chat-list:tail` for the far end), `scripts/dev-linuxapp.sh do chatlist` then `shot` on Linux, and `TAILSCODE_CHATLIST_FIXTURE=1 TAILSCODE_OPEN_CHATS=1` with `--demo` on the phone.

## What was wrong

Ranked by what it costs a person looking for the chat that needs them.

1. **Unread does not read.** The only differences are a weight step (regular to semibold at 13 pt, light on dark glass, where irradiation closes most of the gap) and a dot that trails the title, so it sits wherever the title happens to end and is dropped whenever the row wears a state pill. A failed row that nobody has seen has no unread mark at all.
2. **The title loses its own line.** `PINNED` under the heading PINNED and `SAVED` under SAVED restate the section and take a third of the title. The title and the pills share one compression priority, so on the Mac a `LIVE` pill is crushed to a blob while a `PINNED` pill crushes the title instead.
3. **The loudest ink on every row is the least useful fact.** The model in its family hue and the effort in its heat (a nine-letter rainbow for ultracode) lead the second line of every row, and are the same two words on most of them. Colour should be spent on state.
4. **A desktop row never says what happened.** The phone has had a news line since Home was rebuilt (`ChatRowNews`); the desktops show the same `model effort project · machine` whether the chat finished a minute ago, failed, or has not moved in three weeks.
5. **Nobody is told what the agent said.** Even the phone's news line for an unread finish is the one word "Finished". The answer is the news.
6. **RECENT is one run of 1,800 rows** under a heading whose only fact is "1800". There are no landmarks in time, and the count is not something anyone acts on.
7. **An idle row wears a mark.** The state column draws `·` for a row doing nothing, so the column cannot be scanned for the rows that are doing something.

## Principles

- **The left column is where the eye runs, and a mark in it always means something.** A state (waiting, working, failed, offline) or the unread dot. A read row at rest has nothing there. The dot never trails a title again.
- **Three rungs of ink.** Waiting on you and unread are semibold at full strength. Working is regular at full strength. Read is regular one step back (84% title, 62% chip). Read must still pass for body text: the mocks tried 68% and it greys the nine rows in ten a person scans to resume something.
- **A row with news says it, in words, on its own line.** What a waiting turn wants, what a working one is on, that it failed, that its machine went quiet, and for a finished turn nobody has seen: the first words of the answer. A read row at rest says nothing and stays two lines, so height itself is a signal.
- **The title has its line to itself.** No pills. State is the mark in the column plus the news line. Pinned and saved are a small glyph, drawn only where the heading does not already say it (a pinned chat listed under WORKING).
- **Who and where, then with what.** The last line leads with the project a person recognises the chat by, then the machine, then the model chip, then the age in its column. The chip keeps its hues and steps back with the row.
- **Time has landmarks.** RECENT becomes Today, Yesterday, Previous 7 days, Previous 30 days, then months, then years.
- **A heading counts only what is acted on.** NEEDS YOU and WORKING keep their totals. Every other heading says how many of its rows are new, and nothing when none are.
- **One grammar on three desks.** The phone keeps its tile, lit only when there is something to know.

## The row

| | Desktop | Phone |
|---|---|---|
| State column | 16 pt. Activity badge, else the accent dot when unread, else empty | The 30 pt tile. Tinted and drawn for a state or the unread dot, clear otherwise |
| Line 1 | Title, then pin / bookmark / clock glyphs | Same |
| Line 2, only with news | One line; an unread answer may take two | Up to two lines |
| Last line | project · machine, chip, age right-aligned (hover verbs replace the age on the Mac) | Same |

News, in the order it is decided (`ChatRowNews.reading`):

| Row | Words | Tone |
|---|---|---|
| Waiting to run something | `ApprovalAsk` lead and object when this device holds the call, else "Needs approval" | label |
| Asked a question | the question | label |
| Stuck | "Stalled", the task and how long | label |
| Working / background | the step, the agent's task, or "Working" | accent |
| Failed | "Last turn failed" | danger |
| Offline | "Last heard 3h ago" | secondary |
| Unread, finished | the answer's first words (`lastWords`), else "Finished" | label at 80% |
| Read, at rest | no line | |

## What the agent said

`lastWords` is one optional string on a listing row: the first sentence or so of the last answer of a turn that has closed, markdown stripped, cut at 200 characters. claude-bridge reads it from the transcript's tail when the file changes (the same pass that reads the model and whether the turn is closed), so a listing costs nothing more per request. It is absent while a turn is open and on a server that cannot say (opencode, an older bridge), where the row says "Finished". The Kit carries it as `AgentSession.lastWords`.

## Sections

`ChatListSections` (Core) is `groupIntoSections` with RECENT split by `RecentBucket` on the device's calendar: today, yesterday, previous 7 days, previous 30 days, a month by name inside the current year, a year. Home's bands keep `groupIntoSections` and their own limits. A heading's facts are `SectionHeading`: its title, the total only for NEEDS YOU and WORKING, and the count of unread rows elsewhere.

## Mocks, and what looking at them changed

- **The ladder decided the dimming.** A (weight and dot only) left the rainbow on a read row as the brightest thing in the list. C (68% / 45%) found unread instantly and made the archive grey. B (84% / 62%) is the design.
- **An unread answer gets two lines on the desktops too.** One line cut "Dark mode is in for Settings: every row reads from the pal…" at exactly the word that mattered. Unread rows are few; the second line is the payload.
- **Needs-you is semibold.** In the first pass a waiting row was regular weight under an amber heading and read as quieter than the unread row below it.
- **The failed line is red, not grey.** It was drawn in the unread ink and looked like an excerpt.
- **The phone keeps its gutter.** Dropping the tile on a read row and pulling the title left was tried on paper and rejected: the titles of one list would start at two edges. The tile is cleared instead.
- **The list is about a fifth taller for the same chats.** Headings in time and three-line rows cost height; the titles gained the width the pills had.

## What the real clients changed

- **The last line sheds whole facts.** At a 240 pt Mac sidebar the first build cut the chip mid-word ("ult…"). The row now holds every length the line can be said in and draws the longest that fits: without the effort, then without the model, then the project alone.
- **A turn in flight is never weighted for being unread.** Its clock moves with every token, so it is unread for as long as it runs; weighting it weighted the whole WORKING section.
- **The phone's working words take the tile's tone.** A green tile over blue words read as two states.
- **The figure beside a phone heading is two thirds its size.** At the prominent heading's own size "1 new" read as part of the name.
- **Linux says pinned in a word.** A text client has no symbol set, and `⌃` after a title was a mark somebody had to learn; the clock glyph the list already used stays.
- **A heading never gives up its own letters.** The first GTK build let the count beside it take the width and drew "NEEDS Y…".

## Not changed

The MISSED block on the desktops still lists what `ActivityInbox` holds. With rows saying their own news it repeats them, and whether it stays is a product decision rather than a layout one.
