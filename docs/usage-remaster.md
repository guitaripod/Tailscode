# Usage remaster (iOS screen + Home Screen widgets)

Scope: `UsageViewController` and its cards on iOS, and the `UsageWidget` families. Presentation only — what the numbers are (`QuotaBoard`, `QuotaRollup`, `WidgetGlance`) does not change, so no `AppCapability` case changes and Mac/Linux keep their own surfaces. Mocks: `docs/usage-mocks/usage.png`, `docs/usage-mocks/widgets.png` (sources beside them).

## Look

Read from the simulator in demo mode (before screenshots are in `usage-mocks/assets/`), sizes in points, ≈ because they are read off images:

- The page is ≈1,465 pt tall on an 874 pt screen: 1.7 screens to read four providers.
- ≈205 pt is spent before the first fact: a back button row, a 34 pt large title, a centred "Updated just now", then the chips.
- The hero card (≈237 pt) restates the first window of the first card below it (Claude · Session 62% appears twice, two inches apart).
- Every provider card carries its own "How this is counted" row (≈45 pt each, identical in every card).
- The two unconfigured providers (DeepSeek, Ollama Cloud) are 163 pt each — three-line paragraphs and a text link — for something the person has not asked for.
- Resets are monospaced fine print under every label, which doubles the height of a row and makes the page read like a log.
- The chip row clips ("Ollar") because the chips share the width equally instead of taking their own.
- Controls wear the system blue (`ellipsis.circle`) against brand-coloured cards.

Widgets (same screenshots, `--widget-preview*`): bars and percentages are the app accent (cyan) on every provider, so the only trace of who is who is a 5 pt dot; the large widget's title sits against the top edge; medium rows truncate to `DeepSeek · Balan…` and the header sentence is shrunk to illegibility to fit; a small balance floats in the middle of an empty tile; the empty widget is flat black and says nothing about what to do.

## Principles

1. **One fact once.** The lead is a summary of the next send, not a copy of a bar. It stays (the doctrine: the tightest window decides when the next send unlocks) but at a third of the height, with a one-word verdict.
2. **A row is one idea in two lines.** `Session · resets 2h 47m … 62%`, then the bar. The reset is a clause of the label, not a second line.
3. **Colour says who until it has to say how much.** Bars and dots wear the provider; amber at ≥ 60%, red at ≥ 85% and for a wall — the existing ramp. Meaning outranks branding, as before.
4. **Unconfigured things are one card.** "More providers" lists what could be added, one row each, one tap.
5. **Explanations are not per card.** "How this is counted" is one footer for the page, and it expands to every provider's own note.
6. **The widget is the screen's row at small size** — same anatomy, same colour rule, same words.

## Design — screen

Top to bottom, 16 pt gutters, 10 pt between cards:

| | |
|---|---|
| Navigation | inline title "Usage" with the freshness line beneath it ("Updated 2m ago", "Asking the providers…"); back at leading, the board menu (arrangement, lead, per-provider switches) at trailing. No large title. |
| Chips | the provider switches as intrinsic-width capsules in a horizontally scrolling row, brand dot + name, dimmed while hidden. |
| Lead | a 112 pt card: 84 pt ring (9 pt stroke, ramp colour) with the figure, beside `NEXT SEND · TIGHTEST WINDOW`, `Provider · Window`, `resets in 2h 47m` and a verdict pill (*Room to spare* / *Getting tight* / *Nearly out* / *Used up*). Balance leads read as money with no ring. |
| Provider card | header: brand dot, name, plan, LIVE/CACHED chip, `…` menu in secondary ink. Rows as in principle 2; a balance row is `Balance … $104.32` with its composition as the clause. |
| More providers | one card, a row per offer: 34 pt brand tile, name, one line, `Add key`. Hidden offers stay hidden. |
| The month | unchanged in content (`MonthCard`), restyled to the card family. |
| Footer | one row, "How this is counted ›", expanding in place to each provider's provenance note and detail rows (plan, window, most-used model) — they are per provider, so they could not simply be deleted from the cards. |

Expected: ≈ 840 pt, one screen on a 6.1″ phone at default type size.

## Design — widgets

- **Colour.** `.theme` under the System theme resolves `ok` and `balance` rows to the provider's brand rather than the platform accent; a chosen theme still wears its palette. Warn/danger are unchanged.
- **Row.** Label (primary) + provider short name (secondary, only when more than one provider) + value; bar beneath; the caption only where the family has room.
- **Small.** header (`Usage` / provider name, `+N`, LIVE dot), ring 50 pt with window, provider and reset beside it, two rows. A wall shows the ring full red with the words *Used up* beside it, not inside it. A balance is the figure at 31 pt with its two facts beneath. Empty: canvas background, and what to do ("Open Tailscode once and pick a server").
- **Medium.** hero column (ring 64, `Provider · Window`, reset) beside up to four rows each led by a brand dot so the provider is a colour first and a word second; the header carries a short verdict ("all clear", "Claude 88%") or none — never a shrunken sentence.
- **Large.** a card per provider (dot, name, plan, reset), its windows as rows, a balance as one line; footer "+N more · updated …"; content inset so nothing meets the container's edge.
- **Accessory families** keep their words and shapes (Lock Screen is one ink); they get the same short verdict.

## Mocks, and what looking at them changed

- The first render of the screen mock lost the ring's figure (a CSS mask over the whole element). Fixed in the mock; nothing to do with the design.
- Seeing before and after together confirmed the page now ends inside one screen — which makes the order matter less, so the month stays last and does not need a promotion.
- In the small widget a full-red ring cannot hold the words *Used up* at 10 pt (they collided with the stroke). Decision changed: the ring is a full red stroke with an exclamation mark and the words move to the label beside it.
- The medium's long header sentence from the shipped widget does not survive a 364 pt tile at a readable size; replaced by a short verdict.
- The brand-first rows make the large widget read as four distinct providers at a glance, which the cyan version did not.

## Built, and what building changed

Files: `Tailscode/Usage/UsageCards.swift` (new — every card), `UsageViewController.swift` (composition, navigation title, board menu), `RingGaugeView.swift`; widgets in `TailscodeWidget/UsageWidgetViews.swift` and `UsageWidget.swift`; Core `QuotaSurface.Pressure` (the four words and their two thresholds, shared by the ring colour, the bar colour and the pill) and `WidgetGlance.headline`/`heroIsWalled`. Six new strings in all eleven languages.

Looking at the real build, as the mocks had done before it, overturned five things:

- **The per-card fold held real content.** Provenance and detail rows are per provider, so the footer expands to a section per provider rather than one generic sentence.
- **Light mode.** The shipped screen drew its cards in `secondaryBackground`, which equals the page in light, so the cards were invisible. Cards now use `groupedSurface`, which is what the token exists for.
- **The chips stretched to equal widths and clipped** (`Ollama Clo`) in the shipped screen too: a stack in a scroll view with low hugging. Chips take their own width and scroll.
- **Accessibility sizes.** At the largest Dynamic Type the compact rows broke (the ring figure truncated to `6…`, offer names to `DeepSe…`). The lead, the offers and the month header now reflow to a vertical arrangement, and the page re-renders when the content size changes.
- **Widget row grid.** `layoutPriority` on a label column made it claim the width a wide tile's bar column is meant to fill, so the large widget's bars stopped short of the card edge. It is applied only where several providers share a row (small, medium), where it is what stops `Balan…`.

Read off the final screenshots of the demo data (points, ≈): the scrolling content is ≈ 930 pt against ≈ 1,465, about 1.1 screens against 1.7 — the design expected 840, and missed because the two offer rows wrap their one-liners to two lines; the lead is ≈ 119 pt against ≈ 237; the unconfigured providers ≈ 186 pt against ≈ 326. Screenshots: `usage-mocks/assets/after-*.png`.

## Out of scope

The analytics screen (`AnalyticsViewController`) and the share card keep their content; they inherit the card family but are not redesigned here. Mac and Linux usage surfaces are unchanged.
