# Store pictures for the buyer: leave your desk, it finds you (2026-11-13)

Asked for (2026-11-13): "the marketing pictures aren't selling the app that well, maybe. think about what they should show instead and make it get more downloads. update the header images too." This file is the contract. It replaces the iPhone and iPhone Duo panels and the product page creative of `docs/marketing-1.79.md`; that file's listing text, iPad and Mac sets stand.

## 1. What the fleet set did (App Store Discovery & Engagement by device, sales by device in myyty)

| iPhone | 2026-10-01 to 10-30 (October set) | 2026-11-01 to 11-11 (fleet set, live with 1.80) |
|---|---:|---:|
| Search impressions a day | 908 | 858 |
| Search impression to page view | 4.7 % | 3.6 % |
| Browse impression to page view | 17.3 % | 10.6 % |
| First downloads a day | 3.8 | 2.3 |
| Store page views to first downloads | 6.3 % | 5.8 % |

The 1.79 targets were 8 % and 25 %. The fleet set missed both and the search card got worse, with the same impressions. September's set ("Send. Pocket it. Get pinged.", "When it asks, you answer") had the best iPhone search rate of the three, 6.5 %. Mac search is still noise (88,130 impressions at 0.3 % in November) and is not the target.

## 2. Why

1. **The set talks about the product, in the product's nouns.** "All your agents. One pocket.", "Any agent. Any model.", "Look in on any agent" describe a fleet. The person who typed `claude code` into search runs one agent on one computer and wants to get up from it.
2. **It is the category's sentence.** On 2026-11-13 the first panels of Happy (1,064 ratings), T3 Code (226), Paseo (115), Lody and OpenCode Mobile all say every agent, every machine, at once, most of them over a dark screen of small text. Tailscode's card is one more of those, with 3 ratings.
3. **Nothing in a panel is big enough to read in the search card.** Every panel is a whole dark screen at about 1:1. At thumbnail size the set is ten dark rectangles and a headline.

## 3. The story (D37 of the Midgar decisions: a purchase surface is about the buyer)

The buyer's day in three pictures, which are the search card: **they leave the desk and the agent reaches them, it asks and they answer with a tap, they come back to finished work.** Then why this app over the others (their own machines, no relay, no sign-in, one line to set up), then breadth for the people who run more (every agent, any model, steering, schedules, cost).

Two things make a panel readable small: the Lock Screen's own colour on the first one, and one proof object lifted off the screen on the three panels of the search card and on the cost panel (`lift` in `marketing/captions/layout.json`, `lifted` in `scripts/market-compose.py`): the part of the screenshot the claim is about, on a card's corners with the accent hairline, the device dimmed under it. Panels 5, 6 and 9 carry none: their screens lay out differently in each language, and a fixed crop cut through text in several.

### iPhone and iPhone Duo panels (en-US; the Duo tells the same ten)

| # | Slug | Master | Headline | Subline |
|---|---|---|---|---|
| 1 | 01-leave-your-desk | `lock` (Duo: the Agents board) | Leave your desk. **Your agent finds you.** | Claude Code, opencode and Hermes keep working on your own computer. |
| 2 | 02-it-asks | `03-approval` | It asks. **You tap Approve.** | Risky commands wait for you and your Face ID, wherever you are. |
| 3 | 03-finished-work | `07-home` | Come back to **finished work.** | What ran, what changed and what is done, waiting in your pocket. |
| 4 | 04-your-machines | `welcome` | No relay. No sign-in. **Just your machines.** | Your iPhone talks to your computer over your own Tailscale. Nothing sits in between. |
| 5 | 05-one-command | `fl-setup` | One line. **Then scan.** | unchanged |
| 6 | 06-every-agent | `fl-agents` (Duo: the wall) | Every agent. **One board.** | Claude Code, Hermes, opencode and any ACP agent, on your own computers. |
| 7 | 07-any-model | `fl-models` | Any agent. **Any model.** | unchanged |
| 8 | 08-steer | `fl-steer` | Steer it **mid-run** | unchanged |
| 9 | 09-every-morning | `fl-later` | Ask every morning. **Your machine does.** | unchanged |
| 10 | 10-costs | `14-analytics` | See what **it costs** | unchanged |

Dropped: the wall as its own panel (it carries panel 6 on the Duo), Peek, carry and the party. They are in the app and in the description; they are not why someone installs.

### Product page creative

- **Search results (3840x2560):** "Leave your desk. Your agent finds you." beside the Lock Screen phone, its Live Activity lifted over the bezel.
- **Header (3840x1646):** the same line over three phones: the approval, the Lock Screen with its activity lifted, Home with what finished.
- **Universal (5244x2950, text-free):** the approval a chat asks for, with its three answers.

## 4. Facts checked against the source

- An approval asks for Face ID or the passcode (`03-approval`, 1.79 fact-check): the caption says "you and your Face ID".
- "No relay. No sign-in." is the welcome screen's own second line ("Point to point over your own tailnet. No relay, no sign-in."), in every language in the app's own word for signing in. Never "no account": the App Store apps keep a Midgar ID, the App Privacy label says so, and the site dropped that claim for the same reason. The first cut of this set said "No account"; it was replaced before the experiment started, and the French and Spanish panel 5 and staged listing text (`marketing/listing-pro/`), which had translated "No sign-in" as "no account" since 1.80, were corrected with it. "No analytics" is still not claimed.
- "8 finished today" and "1 working" are the demo world's Home.
- The Lock Screen master is 2026-10-13's (`scripts/shots.sh lock` drives Device Hub at the Mac); the widget target has not changed its Live Activity since.

## 5. What is staged, and what is not

- iPhone and Duo panels, 15 caption locales each (150 + 150): `marketing/appstore/panels/`, staged in `store/shots/{iphone,duo}/` (en-GB and en-AU copy en-US, es-MX copies es-ES). `scripts/market-validate.py iphone`, `duo` and `ipad` pass. Several languages carry a shorter headline than a word-for-word one so the set keeps its size (`--check-fit`).
- The Duo set needed three new captures a locale (`scripts/shots-duo.sh` screens `approval`, `home`, `welcome`); the Duo's first panel shows the Agents board, because no Duo Lock Screen master exists (that capture drives Device Hub at the Mac).
- Creative, every locale: `marketing/appstore/creative/<locale>/`.
- **Not localized: the Lock Screen master.** Panel 1 and both creative images use the English capture in every language (the date and "Awaiting your approval" stay English). Take `TAILSCODE_SHOT_LOCALE=<locale> scripts/shots.sh lock` per locale at the Mac, with the desktop free, before the release that carries this set.
- **Unchanged: the iPad and Mac sets and the preview.** They still tell the fleet story. The iPad is 6 % of downloads and the Mac's limit is search relevance, not pictures. `scripts/market-validate.py mac` fails as it did before this work: the Mac captions name `07-every-morning` and the panels on disk are still `07-ask-anything`, in all eleven Mac locales.
- The landing page (midgarcorp.cc/tailscode, in the Midgar monorepo) leads with the same line and shows the approval in its hero.
- Nothing is uploaded with a version: no release is cut (2026-11-13). See §6 for the test that needs none.

## 6. How it is judged

A Product Page Optimization test needs no app version, so the set is tested before any release carries it: experiment `75d43cb8-a274-4384-b841-d4784af3aa3b` "Leave your desk (D37)", iOS, one treatment at half the traffic, en-US only, submitted for review on 2026-11-13 (review submission `6648ae8f-f26f-4dea-978c-cdbcf58afb85`; the first, `136220dc`, was withdrawn the same evening to correct panel 4). The treatment replaces the ten iPhone panels, the ten Duo panels, the header and the search image; the iPad panels are the live ones; the App Preview is removed from the treatment, because on a search card it takes the first slot with the fleet tour's dark board and the test is about what the card shows first. An experiment can only be started once Apple accepts it: LaunchAgent `cc.midgarcorp.tailscode-ppo` (`~/Library/Logs/midgar/start-tailscode-ppo.sh`, log beside it) checks every half hour, starts it and posts one notification.

Read Apple's result at significance or after 90 days; at about 430 store page views in eleven days it will take most of that. Until then, weekly, from the same reports as §1: iPhone search impression to page view (target 6 %, about September's rate) and iPhone first downloads a day (target 4). The experiment's own numbers split the two halves; the device reports do not. Report a miss plainly. If the treatment wins, it becomes the set of the next release in every locale (already staged, §5); if it loses, restore `store/shots` and the creative from the commit before this one.
