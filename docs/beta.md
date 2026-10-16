# Beta

A beta is an invitation with its footing stated. It is never a warning and never a place to hide
things that are unfinished. One catalog in TailscodeCore describes every feature that is in beta, one
mark and one card are drawn from it on every client, and a feature leaves beta by its case being
deleted, so every client loses the mark together.

## The catalog

`BetaFeature` is an enum (`delegate`, `voiceCall`). Each case answers `BetaCard`:

- `name`, `symbol` (an SF Symbol for the Apple clients) and `glyph` (one column for the text clients)
- `title`: "Delegate is in beta"
- `lead`: one sentence on what it is for
- `paragraphs`: why it is in beta, the ones Delegate already had
- `works`: what is solid, as short lines
- `rough`: what is not, as short lines, and honest
- `changes`: `BetaChange(since: SoftwareVersion, line: String)`, newest first, authored only where there
  is a real change to report. A feature with none shows no such section; nothing is invented.
- `reportName`: where its log lives, in words a person can act on

Nothing in a client spells a beta word. `BetaWords` holds the shared ones (`BETA`, "Got it",
"Copy report", "Report copied", "Since you last looked").

## The mark

`BetaBadge(feature)` is the capsule beside a feature's title on every client. Its tap or hover opens the
card. Where a line already says something, `BetaWords.marked(line)` puts the mark in front of it.

The mark has a freshness, `BetaFreshness`, read from `BetaSeenStore` (one key per feature holding the
version it was last opened at):

- `unseen`: the person has never opened it
- `changed`: opened at an older version, and the card has a change newer than that
- `settled`: opened at this version, or nothing newer to say

A fresh mark (`unseen`, `changed`) is announced once: a light crosses the capsule, and a `changed` card
leads with "Since you last looked". A settled mark holds perfectly still, the way a settled state does
everywhere else. The sweep is arithmetic in `BetaSheen` (position from absolute time, a single pass of
about 1.4 s, nothing at all with reduced motion), drawn from the display's own clock. Opening the card
marks it seen. Nothing nags: no badge dot, no modal, no repeat.

## The card

A sheet on the phone sized to its words, a popover that stays while the pointer is on it on the
desktops. In order: the title with the mark, the lead, "Since you last looked" when `changed`, the
paragraphs, two short lists ("Solid" and "Still rough"), and two actions: Copy report and Got it.

Copy report puts `BetaReport.compose` on the pasteboard: the feature, the app version and system, and
the lines the feature's own surface supplies (a delegate run's daemon address and version, a call's
gateway address and version). It leaves the device only when the person pastes it somewhere. Nothing is
sent to Midgar or anyone else.

## Accessibility

`BetaCard.spoken` is what a screen reader hears where a sighted person sees the capsule. The two lists
are read as lists. Reduced motion drops the sweep and keeps every word.

## Where it is used

Delegate's board title, the server row's line, and the voice call's surface and its entry point. The
parity capability is `betaMark`; every client answers it with the shared badge's anchor.

On iOS the mark is `BetaBadge` (a `UIControl`: `init(feature:reportLines:)`) and the card is
`BetaCardViewController`, a sheet sized to its words with a large detent behind it. Opening the card
reads the mark's freshness first, so a `changed` card leads with what changed, and then marks the
card seen at the version `AppInstallProbe` reads. The pass of light is a gradient layer positioned
from `BetaSheen.progress` off a `CADisplayLink` that is invalidated the moment the pass ends, at most
once per process per feature, and not at all under Reduce Motion; a settled mark runs no clock. Copy
report puts `BetaReport.compose` on the pasteboard, and the button reads `Report copied` for 1.5 s.

On the Mac the mark is `BetaBadge` (an `NSControl`: `init(feature:reportLines:)`) and the card is
`BetaCardViewController` inside an `NSPopover`, one pair for every feature in beta. Resting the pointer
on the capsule opens the card; the card stays while the pointer is on the capsule or on the card and
leaves 0.35 s after it is on neither, and a click, Space or Return opens it too for a trackpad and for
VoiceOver (Escape closes it). Opening the card reads the mark's freshness first, so a `changed` card
leads with what changed, and then marks the card seen at the version `MacAppInstall` reads from the
bundle. The pass of light is a gradient layer positioned from `BetaSheen.progress` off the capsule's
own display link (`NSView.displayLink(target:selector:)`), removed the moment the pass ends, at most
once per process per feature, once the mark is actually on screen and not at all under Reduce Motion
(`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`); a settled mark runs no clock. Copy
report puts `BetaReport.compose` on `NSPasteboard.general`, and the button reads `Report copied` for
1.5 s. The delegate board supplies the daemon's address, state and version; the call's strip supplies
the gateway's (`VoiceCallReport`).
