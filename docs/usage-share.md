# The usage share: modules, formats, and the painter contract

The month-in-numbers share is a picture the person composes: a **format** (the canvas), a set of
**modules** (the sections), a **look** (the palette). Core decides every word, every rectangle and
every line count; a client paints. The Linux client is the reference painter
(`TailscodeLinux/.../AnalyticsCardRenderer.swift`, `ShareCardDialog.swift`); the Mac and iOS
follow-ups translate it.

## Core types (`TailscodeCore`)

| Type | File | What it is |
| --- | --- | --- |
| `ShareFormat` | `ShareModule.swift` | `post` 1600x900 (X's in-feed image, the default), `square` 1080x1080, `portrait` 1080x1350 (4:5), `long` (1080 wide, as tall as its content). Capacity 4 / 4 / 6 / unlimited. Logical points, rasterise at 2x. |
| `ShareModule` | `ShareModule.swift` | `hero` (always drawn, not selectable) and the selectable `activity daily week providers models projects tools tokens records insights`, in the one order they are drawn. `isAvailable(in:)`, `unavailableReason(in:)`, `title`, `symbolName` (an SF Symbol name; map it to your icon set), `footprint(in:)`. A one-case follow-up adds `local`: add the case, its `isAvailable`, its builder in `TileBuilder.blocks(for:)`, and its place in `ShareModule.priority`. |
| `ShareFit` | `ShareModule.swift` | What a choice becomes for an account: `shown`, `dropped` (left out for room), `unavailable` (module to reason), `note` (the sentence for the dropped ones), and `state(of:)` for a chip: `.on`, `.off`, `.blocked(reason)`. |
| `ShareSelection` | `ShareModule.swift` | `format`, `style: CardStyle`, and each format's own modules (`chosen`; a format nobody has touched wears `ShareFormat.curated`). `fit(_:)`, `toggle(_:in:)` (returns `.added`, `.removed` or `.refused(reason)`), `forgetChoices(for:)`. |
| `ShareSelectionStore` | `ShareModule.swift` | `load()` / `save(_:)` over `UserDefaults`: `tailscode.shareFormat` and `tailscode.shareModules` (`post=daily,models;long=...`). The look stays `CardStyleSelection` (`tailscode.shareCardStyle`). Linux captures both new keys in `SettingsFile`. |
| `AnalyticsShare` | `AnalyticsShare.swift` | `card(_ selection:, dark:)` the picture; `caption(_:)` the post's words; `altText(_:)` the picture's description; `plainText`, `markdown`, `filename` as before. `share.card` is still the full-length card with every classic module, which the unchanged Mac and iOS painters draw. |
| `AnalyticsShare.Card` | `AnalyticsShare.swift` | `palette`, `format`, `canvasWidth`, `height`, `panels`, `footer`, `fit`. `with(palette:)` re-skins. |
| `Card.Panel` | `AnalyticsShare.swift` | `module`, `rect`, `surface` (`.bare` or `.raised`), `corner`, `inset`, `metrics`, `blocks`; `content` is the rect less the inset. |
| `Card.Metrics` | `AnalyticsShare.swift` | `contentWidth`, `scale`, `heroSize`, `dailyHeight`, `weekdayHeight`: the type and spacing a panel's blocks are measured in. `Metrics.long` is the old card's. |
| `Card.Footer` | `AnalyticsShare.swift` | `rect`, `left` (where the numbers came from, plus coverage and not-counted notes), `right` ("API-equivalent estimate · not a bill"), `size` (20), `leftLines` (1 or 2). Poster formats only. |
| `ShareFixtures` | `ShareFixtures.swift` | Deterministic accounts for tests and dumps (below). |

`Block` gained `.stats([Stat])` (two-across big numbers); `DayBar` gained `isPeak` (the one accented
bar in a tile).

## How a painter walks a card

```
fill the canvas: canvas colour, falling to canvasEnd along the canvas (the old card's gradient)
for panel in card.panels:
    if panel.surface == .raised: fill the rounded rect (panel.rect, panel.corner) with palette.raised
    clip to the panel's rounded rect
    y = panel.content.y
    for block in panel.blocks:
        paint(block) at (panel.content.x, y) in panel.metrics
        y += Card.height(block, in: panel.metrics)
    unclip
if card.footer: left text at footer.rect (leftLines lines, ellipsised, width = rect less the right text),
                right text right-aligned in footer.rect
```

A painter never measures text to place anything: line counts come from `Card.lines(_:in:)`, heights
from `Card.height(_:in:)`, sizes from `Card.fontSize(_:in:)` (all scale-aware through `Metrics`), bar
widths from `Card.barGeometry(count:in:)`, a meter's track at `Card.meterTrackOffset * scale`, a stat
row's pitch from `Card.statRowHeight(scale)`. The single-line text a block carries is already cut to
its width by Core (`Card.truncated`), so every desk shows the same letters; a painter still
ellipsises as a safety net. The full-length format is one panel (`rect` = the canvas, `inset` 56,
`metrics = .long`, no footer; its footer is `.foot` blocks), so one loop draws every format.

Block drawing, in the reference painter's terms (sizes are the constants in `Card`, times
`metrics.scale`):

- `brand` accent, bold, tracking 4; `kicker` text, semibold; `hero` text, bold, **tabular digits**,
  size `metrics.heroSize` (never above 150, the only size above 100); `body` text; `dim` and `foot`
  textDim; `trend` semibold in `warn` (up), `accent` (down) or `textDim` (flat); `section` upper-cased,
  bold, textDim, tracking 2; `insight` text with its prefix.
- `meter`: label semibold left, detail textDim after the label's ink if there is room, money
  semibold right (tabular), a rounded track in `rule` with the fill in `accent` for the `hot` row and
  `info` for the rest.
- `daily`: bars at `barGeometry`, `isPeak`/`isToday` in `accent`, empty in `rule`, others `info` at
  0.85; the axis labels 6 pt under the chart. `weekday`: seven columns, the tallest in `accent`.
- `record`: glyph in `special`, caption (dim, medium) over the value (semibold, tabular).
- `stats`: `Card.statColumns` columns, value bold tabular (44 pt x scale) over its label (textDim).
- Accent is used for exactly one thing per tile: the lead meter, the peak bar, the tallest weekday.

Tabular digits matter because the numbers change from share to share: Linux sets Pango's
`font_features="tnum"` through markup; AppKit and UIKit use monospaced-digit fonts.

## Geometry (all in `PosterPlan`, `AnalyticsShareLayout.swift`)

| Format | Margin / gap | Hero | Tiles | Tile scale |
| --- | --- | --- | --- | --- |
| post | 44 / 22 | bare panel, left, 38% of the width, hero up to 150 pt | right side, grid below | 1.2 |
| square | 40 / 20 | bare band on top, 330 tall, hero up to 130 | 2-column grid | 1.0 |
| portrait | 40 / 20 | bare band on top, 400 tall, hero up to 150 | 2-column grid | 1.0 |

Grid for n tiles: 1 fills the area; 2 stack; odd counts open with one wide tile and then rows of two;
even counts are rows of two (`PosterPlan.grid`). Tiles are raised rounded cards (corner 28 / 24,
inset 28 / 24). The footer is the last line at the bottom margin, 20 pt, so it reads at timeline
size. With no module selected the hero takes the whole area.

Text never overflows a panel by construction and by test (`ShareLayoutTests`): a tile builder adds a
row, a caption or an insight only while the next one still fits the tile's content height, so a meter
section gives up its last rows before any text is clipped; a caption that would have to be cut
mid-sentence is left off; a chart takes the height the text leaves; a meter's detail is whatever
whole phrases still fit; labels and record captions are ellipsised in Core.

## The look

Ten looks as before. A poster (post, square, portrait) opens in **Aurora** unless a look is stored
(`CardStyleSelection.defaultStyle(for:)`); the full-length column keeps "Match the app". A stored
choice always wins, for every format. Why Aurora: Midnight and Aurora both read (their accents
measure 12.7:1 and 11.0:1 at the weakest point of the canvas, its fall and the tiles), so the choice
is about the picture holding its own among X's flat black and navy timelines: Aurora is the dark
look whose canvas falls through a visible colour (teal into violet) and whose tiles are tinted by
it, where Midnight is a quiet navy close to a dark timeline's own ground. That is a judgement made
looking at the renders, not a number; the readability floor is the measured part
(`ShareLayoutTests.posterDefaultReads` asserts 7:1 for the accent and the ink). `CardStyle.published` now also adjusts every slot against the tile colour (`raised`), so ink on
a tile is as readable as on the canvas.

## Caption and description

`AnalyticsShare.caption(_:)`: at most 280 characters, counted by `AnalyticsShare.xLength` (a link is
23, an emoji or a wide-script character 2, everything else 1, as X's own counter weighs them). It
leads with the headline and window, the trend, then one line per shown module in priority order for as
long as they fit; the "API-equivalent estimate · not a bill" line is held back first and goes last
whenever the headline is money. No hashtags, no links, only phrases the usage screen already writes.
`altText(_:)`: at most 1000 characters; the headline and window, the estimate and coverage notes, then
each shown module in words and numbers. Clients offer Copy caption and put `altText` on the picture
(Linux: the preview's accessible description). It is never baked into the PNG.

## Dumping pictures to look at

`TAILSCODE_SHARE_CARD_OUT=<dir>` makes the Linux selftest write `<fixture>-<format>-<style>.png` for
every fixture and format (`TAILSCODE_SHARE_CARD_SCALE`, `_FIXTURES`, `_FORMATS`, `_STYLES` narrow it;
the default look per format otherwise):

```
TAILSCODE_DEV_DISPLAY_NUM=75 TAILSCODE_SELFTEST_ONLY=share \
TAILSCODE_SHARE_CARD_OUT=/path/to/dir scripts/dev-linuxapp.sh selftest
```

`TAILSCODE_DRIVE=...:share=<fixture>` opens the share window on a fixture in the harness app. The Mac
and iOS selftests should dump the same names so the three can be compared side by side.

Fixtures (`ShareFixtures.names`): `rich`, `oneModel`, `twelveModels`, `longNames`, `noDaily`,
`localOnly` (every model free, local), `localSessions` (a session-totals ledger: no tools, no clock),
`tinyWindow` (one active day in the week window), `partialCoverage` (two servers, one coarse, one not
counted), `quarter`, `year`.

## Tests that guard it

`ShareLayoutTests` (the full-length card unchanged block for block and point for point over eleven
accounts, canvases, no panel overflow, geometry, footprints, hero fit, accents), `ShareSelectionTests`
(availability and reasons, capacity, dropping by priority, toggling, per-format memory,
persistence), `ShareCaptionTests` (X length, 280, honesty, the description), `AnalyticsShareTests`
(the original Helsinki fixture). Linux: the selftest's `analytics share` check paints every fixture
in every format and drives the share window.

## What the follow-ups owe

Mac (`TailscodeMac/AnalyticsCardRenderer.swift`, `ShareCardPanel.swift`) and iOS
(`Tailscode/Usage/AnalyticsCardRenderer.swift`, `ShareCardViewController.swift`): replace the block
loop with the panel walk above, move the meter track to `Card.meterTrackOffset`, add the format
picker, the module chips (disabled with `ShareFit.state(of:)`'s reason), Copy caption, the picture's
description, a debounced redraw, and the remembered selection through `ShareSelectionStore`; then
flip each manifest's `usageAnalytics` answer from `.partial` to `.implemented`.
