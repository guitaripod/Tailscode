# Compact chat — what the transcript spends its height on, and what it should cost

Same order as the Studio: **look** (§1), **think** (§2–§3), **design** (§4–§7, with mocks in `docs/compact-mocks/`), then **implement** (§9). Asked for: link embeds are too big and should be one small stack that opens on hover; the chat should be more compact in general, on every client.

## 1. What I looked at

The demo conversations (`demo-c1` reconnect-test fix, `demo-c2` CI migration, `demo-c4` auth flow) on the iPhone 17 Pro simulator, the Mac client rendering a long live agent session with pictures, and the source of every transcript row on all three clients (Core `Typography.spec`, `Theme.Spacing`/`MacTheme.Spacing`, Linux `MatrixTheme` CSS, `ChatRowBuilder`, `TranscriptColumn`, the Linux row builders). Heights below are read off the iPhone screenshot at 402 pt wide (points) and the Mac shot (points); where a number is a source constant it says so.

| Row | Resting cost today | Why |
|---|---|---|
| Link preview card (iOS) | **≈ 54 pt card + 2×6 pt gap per link**, up to 3 per prose segment, so a paragraph with three links costs ≈ 200 pt | icon 30 pt + 12 pt padding; one card per address, one set per segment |
| Context-compacted seam (iOS) | **≈ 110 pt** | rule + card + title + token line + progress bar + explanation sentence |
| Tool row (iOS) | **≈ 36 pt card + 12 pt gaps** per tool, a run of one is not folded | the card chrome (white rounded plate) is the cost, not the words |
| Thinking row (iOS) | ≈ 38 pt fixed | its own card |
| Agent-made picture (Mac/Linux) | **≈ 300–340 pt tall + filename caption** each, two in a row stack | no resting height cap on the desktops, iOS caps at 300 pt |
| Code block (iOS) | **≈ 40 pt of empty space under the last line** | the body is sized past its content; plus a 20 pt header row on the desktops |
| Paragraph / block gaps | 16–20 pt between a paragraph and the block after it (iOS), 12 pt between *every* row (Mac `TranscriptColumn`), 18/26 px padding (Linux, `denseRows` off) | one global gap per client, not per relationship |
| User prompt bubble (iOS) | 56 pt for two lines | 8 + 4 pt padding each side |

Existing knobs: `compactActivity` (iOS) and `compactTools` (Mac, Linux) fold runs of two or more tool calls into one line, default on; Linux has `denseRows`. Nothing similar for spacing on iOS or the Mac, and nothing at all for links, seams and pictures.

## 2. What is wrong, ranked by height wasted per conversation

1. **Furniture is drawn as cards.** Links, seams, tools, thinking, notes each carry their own plate, padding and gap. In an agentic chat there are more of these than paragraphs, so the plates are most of the page.
2. **A fact that is not the answer is shown in full whether or not it is wanted.** A link's title and favicon, a compaction's progress bar, a picture's filename and full size, a code block's header: each says something only on the occasion someone asks.
3. **Gaps are global.** One number between every pair of rows, so a prose paragraph followed by a one-line tool row gets the same air as two paragraphs.
4. **Dead space.** A code body taller than its text, a run of one tool that does not fold, a caption under a picture that repeats its filename.

## 3. Principles

- **Furniture costs a line, not a card.** At rest anything that is not the answer takes ≤ 24 pt, flat (no plate), and says its fact in words, with its tone (a failed tool is still danger-coloured when folded; a running one still breathes).
- **Hover reveals; it never reflows.** On pointer clients an expansion floats over its neighbours (a plate in the overlay layer), so no row moves under the reader's eyes and no scroll anchor changes. On touch the expansion is a tap, in place, with the anchor held.
- **Compaction takes padding, chrome and repetition, never glyphs.** Prose keeps its role, size and leading (the ramp is the one thing that says prompt from answer); code keeps its lines.
- **One density, one place.** The numbers live in Core (`ChatMetrics`, one `ChatDensity` setting); each client maps them onto its own tokens. No cell hard-codes a gap.
- **Honest folds.** A folded row says how much it holds (count, duration, state). Nothing is hidden that would change a decision: a pending permission, a question, a failure and an answerless turn stay open.

## 4. The link rail (replaces the link cards)

One **rail per assistant message**, not a card per address. It sits under the message's last prose row, is **24 pt tall at rest**, and holds every address of that message.

```
 ⬡⬡⬡ github.com · docs.github.com · +1        (rest: favicon stack, hosts, count)
```

- **Rest.** Up to three overlapping 14-pt favicons (the host's glyph until a favicon is known), then the hosts joined by `·` ellipsised to the width, then `+N` for the rest. One address reads as its title instead of its host once known. No plate: the line sits on the canvas in the quiet ink. It appears as soon as the first settled address exists and only ever grows by count; nothing moves when a fetch lands (the line's height never changes).
- **Hover (Mac, Linux).** After a 120 ms rest of the pointer the rail's plate opens *over* the rows below it — a floating list, never a relayout: each address is a 36-pt row (favicon, one-line title, host at the trailing edge, ellipsised), 8 rows visible then scroll, max width 440 pt. Moving the pointer onto the plate keeps it open, leaving closes it after 250 ms, Esc closes it. A click opens the address in the person's own browser, right-click offers Copy address, ⌘/Ctrl-click copies. The rail itself is focusable by keyboard on the desktops (Space/Enter opens the plate, ↑↓ walk it, Esc closes).
- **Tap (iOS).** Tap expands the rail in place into the same rows (160 ms; instant under Reduce Motion) with the scroll anchor held on the rail; tap again collapses. Long-press an address row copies it; an iPad pointer hovering shows the hover highlight only.
- **Fetching.** Titles and favicons are fetched for the first three addresses (the stack) with the existing debounce, and for the rest the first time the rail opens; a streamed address that is still growing fires nothing. This is fewer requests than a card per address, and the failure of a fetch is still not a failure of the link (host alone).
- **Cap.** 12 addresses per rail (was 3 per prose segment), the rest counted in `+N`; same dedup in order, http/https only, `LinkReach` still gates every fetch.
- **Setting.** `LinkEmbedsSetting` stays the one switch (on by default); off means no rail at all. Right-click on the rail: Copy all addresses.
- **Accessibility.** The rail is one disclosure button — "3 links, github.com, docs.github.com and 1 more, collapsed" — and the opened rows are links in reading order.
- **Reading in Core.** `LinkRailReading` (value type, one source of words for all three clients): `items` with state (placeholder / titled / host only), `stack` (≤ 3), the rest-line, the accessibility sentence; policy in `LinkEmbedPolicy` (extraction across a message's segments, dedup, cap 12, still-growing rule); the fetcher is unchanged.

## 5. The rest of the compaction

1. **Activity is a flat line everywhere.** Tool calls, thinking and subagents rest as the Mac's run line today (`▸ 3 tools Read Edit Bash`, tone, elapsed), flat and 24 pt, **including a run of one**, which reads as its own tool name and argument on that same line (`▸ Edit Tests/PulseTests/ReconnectTests.swift`). Thinking is a word in the run's summary (`1 thought`), not a card. iOS loses the plate: the card chrome is the cost. The expanded state is unchanged. A running run breathes; a failed one is danger-toned while folded.
2. **Seams and notes are one divider line.** Compaction: `── Context compacted · 311.6k → 16.4k · 1m 54s ›` (28 pt, was 110 pt); the progress bar and the explanation sentence move to the reader it already opens. Model change, interrupted, restored-from-… notes use the same line.
3. **Pictures the agent made are thumbnails.** ≤ 160 pt tall at rest on every client, **consecutive pictures share one row** (a strip, 8-pt gutters, wraps), the filename is the tooltip and the accessibility label rather than a caption row, a click opens the gallery (unchanged). A lone picture is ≤ 160 pt tall by the width its aspect gives.
4. **Code has no dead space and no header row.** Body height is its content (the bottom 40 pt on iOS goes), the language label and Copy sit on the first line's trailing edge, revealed on hover on the desktops and always on touch; the existing 14-line collapse and its toggle line stay.
5. **Gaps are per relationship** (`ChatMetrics`): paragraph → paragraph, prose → furniture, furniture → furniture, turn → turn, picture strip. Compact values (points): paragraph 8, prose↔furniture 4, furniture↔furniture 2, turn break 16, bubble padding 8/6; comfortable keeps today's.
6. **The prompt bubble** loses 2 pt of padding per side and goes to 85 % max width on iOS; the Mac and Linux accent-rule prompts are unchanged.

Not changed on purpose: pending permissions and questions (a person must see them), the answerless card (it carries the one remedy), the composer and the status strip above it (a separate question: they are chrome the person uses), type size and leading.

## 6. Density: one setting, one table

`ChatDensity` (`.compact` default, `.comfortable`) in Core with a persisted store like `LinkEmbedsSetting` (Settings ▸ Appearance ▸ "Chat density" on all three clients; Linux's `denseRows` is migrated onto it). `ChatMetrics` is the table of numbers above for each density, plus `imageMaxHeight`, `codeCollapseLines`, `activityRowHeight`, `railHeight`. It carries no toolkit types; iOS maps it in `Theme`, the Mac in `MacTheme`, Linux interpolates it into the `MatrixTheme` CSS. `ChatMetricsTests` proves the claims that matter: every compact value ≤ its comfortable value, the resting heights are the ones this document says, and no value is below the 44-pt-on-touch / 24-pt-on-pointer target for anything pressable.

## 7. Alternatives considered

- **Per-segment mini rails** (keep the card position under each paragraph, only shrink): a four-paragraph answer would still carry four rails; the per-message rail costs one line however long the answer.
- **Inline link chips in the prose**: breaks the paragraph's measure and the streaming cascade (the live row must never re-wrap).
- **Hover expands in place** on the desktops: the transcript below the rail would jump under the pointer; the floating plate costs nothing in layout.
- **Collapsing entire finished turns** to a summary line: the biggest saving, but it hides the answer's own evidence; left for later as a preference, not a default.

## 8. Risks and measures

- **Perf**: a rebuild may not cost the size of the conversation. The rail is derived per message and memoised with the segment rows (iOS `SegmentRowMemo`, desktops `TranscriptRowBuilder`), keyed by the link setting and density.
- **Hover on GTK**: menu-button popovers swallow presses (see the capture-press memo); the plate is a non-modal `GtkPopover`-less overlay widget positioned from the rail's bounds, not a popover.
- **Mac frame-placed rows**: the plate is a child of the transcript's overlay layer, not of the row, so `TranscriptColumn`'s frame solver never sees it.
- **Measure**: the three demo conversations at fixed widths (iPhone 402 pt, Mac and Linux 900 pt column) — total content height before and after; target **≥ 25 % shorter** at compact, link-heavy answers ≥ 40 %. Each client logs it (`journey`-style DEBUG line / `--bench` / harness `geom`).

## 9. Implementation (after §1–§8)

1. Core: `ChatDensity` + store, `ChatMetrics` + tests, `LinkRailReading` + policy change (message-wide, cap 12, lazy fetch beyond three) + tests, parity capability (`.linkEmbeds` spec reworded as the rail; new `.chatDensity`), strings.
2. iOS, Mac, Linux in parallel: the rail row replaces the card row kind, flat activity lines, seam/notes line, picture strips, code header/dead space, per-relationship gaps from `ChatMetrics`, Settings control, selftests, before/after content-height numbers and screenshots.
3. Parity manifests honest; installed on every desk it touches.
