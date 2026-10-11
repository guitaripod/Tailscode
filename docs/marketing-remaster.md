# Store panels and the preview video, remastered

Scope: the iPhone, iPad and Mac App Store panels (`scripts/market-compose.py`, `marketing/captions/`), the iPhone's ten panels in all ten store locales, and a thirty-second app preview video made from the app's own scripted tour.

## Look

The panels as shipped (`panels-before` in the session; the old files are in git history):

- Ten panels, one template: the same navy gradient, the same left-aligned headline, a small grey subline, a phone centred below. Down the store's carousel — which shows two or three at a time — nothing changes from one panel to the next, so nothing says *there is more*.
- The headlines name products or describe a feature (`Claude Code, opencode, Oh My Pi — on your phone`, `Every diff, every command, inline`), and the first three are the only ones most people read.
- The type is 104 px on a 1,320 px canvas and the sublines are 51 px mid-grey: at thumbnail size the headline is legible and the subline is not.
- The device sits whole inside the room under the text, so the screen is about two-thirds of the panel's width; the UI inside it is 11 pt mono at best, and unreadable at a glance.
- Two panels (`06`, `07`) show the same conversation with different cards open. The usage panel shows the screen that has since been remastered. Nothing mentions widgets, the cost analytics, or that the app is private and free of accounts — the three things a person deciding whether to trust a remote for their coding agents is asking.
- There is no video.

## Think

A store panel's job is one idea, understood at a glance, in the order a person decides: *what is it*, *why would I trust it with this*, *what do I get*, *what does it cost me to leave it running*. So:

1. **One idea per panel, said as a benefit, in two short lines.** The product names move to the subline, where they help search and cost nothing.
2. **One phrase lit in the panel's colour**, so the thing to remember is the thing that is brightest.
3. **Each panel has its own colour**, so the carousel reads as a rhythm and a person can tell where they are in it.
4. **A bigger screen.** The device is wider than before and may bleed off the bottom where the composer is not the point.
5. **Pull out the one moment that sells**, enlarged, where the UI is narrow enough to enlarge: the Usage ring with its verdict, the month's total.
6. **Prove the claims the product makes about itself**: the privacy panel shows the app's own words on it (`Point to point over your own tailnet. No relay, no account, no analytics.`), which are in the build.

## Design

Ten panels, in this order (the first three carry the pitch; the last is the trust close):

| | Master | Colour | Headline (en-US) |
|---|---|---|---|
| 1 | `01-live` | blue | Your coding agents, **in your pocket** |
| 2 | `03-approval` | amber | Approve it from **anywhere** |
| 3 | `02-dial` | violet | Pick the model. Set **how hard it thinks.** |
| 4 | `07-home-ultra` | green | Every machine, **one board** |
| 5 | `04-question` | cyan | When it needs you, **it asks** |
| 6 | `15-delegate` | pink | Hand off the **routine work** |
| 7 | `08-usage` (the remastered screen) | orange | Know your limits **before you hit them** — with the ring and its verdict enlarged |
| 8 | Home Screen widgets, no device | indigo | Your quotas on the **Home Screen** |
| 9 | `14-analytics` | emerald | See what it **costs**, turn by turn — the month's total enlarged |
| 10 | `welcome` | slate | Nothing leaves your **tailnet** — the privacy list enlarged |

Dropped: the diff/fan-out panels (`06`, `07` — they duplicated each other) and the setup checklist (a how-to, not a reason). The iPad keeps its own ten (it has the workspace, a sidebar and columns the phone does not); the Mac keeps its six. Both take the same type system and colours.

Layout (`marketing/captions/layout.json`, by slug — nothing in it is language): the colour, the device's width (or *fit*, which keeps the whole device in the panel), and the callouts, each a box cut from the master as fractions of it, a scale and a position. The words are in `marketing/captions/<locale>.json`: a headline of exactly two lines, a subline, and the phrase to light.

The widgets panel is not a screenshot of a Home Screen. The app's widget preview (`--widget-preview-store`) lays one tile of every family at its real size on a flat key colour; `scripts/market-widgets.py` cuts them out and the panel sets them as a Home Screen would — two smalls, a medium, a large — on its own ground. They are the same SwiftUI views the widget extension draws.

The preview video (`marketing/video/`): the app's own scripted tour (`--preview-tour`, DEBUG, `TourDriver.startPreview`) — the board, one sentence typed and sent, the answer streaming, the effort rail, an approval, the quotas — recorded off a dedicated simulator, trimmed and scaled to the store's 886 × 1920, with a few words on each beat and an original soundtrack (`scripts/preview-score.py`, written rather than licensed). It is screen only: no device frame, because a preview that is not the app is a rejection.

## Mocks, and what looking at them changed

Designed in the compose script and looked at as rendered (there is no separate mock layer — the panel *is* the mock):

- The first render of the whole set gave the rhythm the old set lacked, and also showed two panels cropping the composer (the dial and the board, whose point is the pill and the composer): those two are *fit*, not bleeding.
- A callout is only worth it where the UI is narrow. The approval buttons and the question card are already the full width of the screen, so enlarging them gains almost nothing; the Usage ring and the cost figure gain a lot. Callouts are on those and on the privacy list.
- A first Analytics callout cut a long line off at its right edge and half-covered text beneath it; the box now ends before a line it cannot hold, and sits so that the card covers what it zooms rather than half of it.
- German and French labels are longer than English: the Usage callout's box and scale leave room for `FENÊTRE LA PLUS TENDUE`.
- The first translations used the word for a medicine pill (`Pille`, `píldora`, `ピル`, `胶囊`) for the model pill despite the brief; they now say selector / model name, as the earlier release notes' rule requires.
