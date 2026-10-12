# Marketing remaster, October 2026 — the contract

Why: the previous set (docs/marketing-remaster.md) was shot on the chat that existed on 5 October. The chat screen has since been redrawn on every client (docs/chat-design.md), the promo text on the live store pages is empty, the preview video carries burned-in captions, the Mac panels are 1.22-era, and the landing page still says the Studio is "in App Review". The research behind these choices is in the Developer Tools review of 35 listings (Moshi, Cursor, T3, Happy, Hermex, Termius, Working Copy, ShellFish, …).

## What wins in this category, and what Tailscode will do about it

| Pattern the best pages share | Tailscode |
|---|---|
| One ground and one accent across the whole set (Cursor off-white, Moshi black-green, T3 flat dark) | Ink ground `#0B0D11`, one amber accent `#FFB547`, warm-white headline, grey subline. No per-panel hue. |
| A caption that makes a claim, big, top of the panel, two or three lines, one coloured phrase | ≤6-word headline, ≤12-word subline, one lit phrase. Headline at least 9% of panel width per cap-height; two lines at most. |
| A real Lock Screen panel | Panel 1. Nobody else leads with it; it is the product. |
| Specific, believable content in the UI | The demo world's `rm`/approval/diff content; no `acme-db`, no lorem. |
| A trust panel with a checkable claim | "Nothing leaves your tailnet": a diagram of two devices and a line, three lines of fact (no relay · no account · no analytics), GPL-3.0. |
| UI large enough to read at thumbnail size | Devices bleed off the bottom edge; the crop is deeper than before so the interesting 60% of the screen fills the panel. Mac and iPad panels crop to the window, not the desktop. |

Avoid: a different gradient per panel, noun-list captions ("Snippets"), sticker callouts that collide with art, stock mood imagery, raw uncaptioned screens, 8-pixel UI in a big frame.

Own what nobody else owns: the Lock Screen as the headline, privacy that can be checked (no relay, no account, no analytics, GPL-3.0), money in dollars (per turn, per month, per machine), three desks (iPhone/iPad, Mac, Linux) from one engine.

## Name, subtitle, keywords

Name and subtitle stay (name `Tailscode: Coding Agent Remote`, subtitle `Claude Code·opencode·Oh My Pi`): both are indexed, the subtitle names the three products the app works with, and a second app-info record is already waiting for review. Keywords change: they stop repeating the category, add `tailnet,quota,usage,spend,widget`, and the Mac set drops the phone-only words. Never add another vendor's product name that the app does not support.

## Panels (en-US claim; the lit phrase is in **bold**)

iPhone, 1320×2868, ten per locale:
1. Send. Pocket it. **Get pinged.** — Your coding agents, live on the Lock Screen, over your own tailnet.
2. Approve the **risky command.** — Allow once, always or deny, while the agent waits.
3. Nothing leaves **your tailnet.** — No relay. No account. No analytics. Open source, GPL-3.0.
4. Every machine, **one board.** — Live turns first, grouped by project, across all your servers.
5. Read the **diff** before you trust it. — Branch, staged, changed: the real patch, from the machine that owns it.
6. When it asks, **you answer.** — A question arrives as a card. Answer with a tap.
7. See what it **costs.** — Every turn priced, every month totalled across your machines.
8. Limits **before the wall.** — Each provider's tightest window and reset clock, on your Home Screen too.
9. Pick the model. **Set the effort.** — One pill carries both. Pin pairs and swipe between them.
10. **Hand off** the routine work. — A cheaper model tries first, a verifier decides. (Beta)

iPad, 2752×2064, ten (en-US):
1. One workspace, **every agent.** 2. Approve with the **list in view.** 3. A fan-out, **at a glance.** 4. Real output, **right there.** 5. Read the **diff** first. 6. Every quota, **before the wall.** 7. The month **in numbers.** 8. Nothing leaves **your tailnet.** 9. **Hand it down** the ladder. 10. The whole screen, **one workspace.**

Mac, 2880×1800, ten (en-US, framed MacBook, window cropped large):
1. **Native** on the Mac. 2. Two machines, **side by side.** 3. The repo, **read — never operated.** 4. **One chord** from anywhere. 5. A price on **the whole conversation.** 6. The month **in numbers.** 7. Approve **without switching apps.** 8. **Keyboard** first. 9. A size for **every part** of the window. 10. Nothing leaves **your tailnet.**

## Preview video

Plain app footage, no frames, no captions, no overlays (the vault rule, and Apple's): iPhone 886×1920, ≤30 s, 30 fps. 0–4 s Lock Screen Live Activity ticking, then the buzz; 4–10 s approval card, Allow once; 10–15 s a question answered with a tap; 15–20 s the board across two machines; 20–25 s a diff, then the month in numbers; 25–30 s the tailnet screen. Poster frame: the Lock Screen. The framed 1080×1920 cut with captions is for social and the landing page only.

## Store text

Canonical copy lives in docs/asc-listing-l10n.json and docs/asc-listing-l10n-macos.json (13 locales; `pl` is on the store but was never canonical and is added). Every field is verified against Apple's limits by a script before anything is written: name 30, subtitle 30, promo 170, keywords 100 bytes, description 4000. The live promo text is empty on every version; the new promo is written for conversion (it does not affect ranking).

## Shipping

A store listing can only change on an editable version: iOS 1.75 is live and Mac 1.75 is in review, and neither carries the redesign, so the new panels, preview and copy ship with iOS 1.76 and the next Mac build. Until then everything here is built and verified locally; nothing is uploaded, no version is created, and the landing page is committed but not pushed.
