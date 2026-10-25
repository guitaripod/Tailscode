# Store remaster for 1.79: the fleet story

Asked for (2026-10-25): find out why Tailscode gets so few downloads for its impressions, then remaster the listing, the panels and the preview for the next version, telling a better story drawn from how the app is really used. This file is the contract. The October remaster it replaces is `docs/marketing-2026-10.md`. The ASO history is in `docs/aso-2026-09.md`.

## 1. The funnel (App Store Discovery & Engagement + App Downloads Standard, 2026-09-29 to 10-23)

| Surface | Impressions | Page views | First downloads | Impression → view | View → download | Impression → download |
|---|---:|---:|---:|---:|---:|---:|
| Mac App Store search | 65,007 | 485 | 37 | 0.7 % | 7.6 % | 0.06 % |
| iPhone search | 14,945 | 802 | 135 | 5.4 % | 16.8 % | 0.90 % |
| iPad search | 4,816 | 118 | 26 | 2.5 % | 22.0 % | 0.54 % |
| iPhone browse | 1,354 | 305 | 24 | 22.5 % | 7.9 % | 1.8 % |
| All | 86,731 | 2,245 | 255 | 2.6 % | 11.4 % | 0.29 % |

The October panels and preview (live since 1.75) did not move the funnel. Compared with September, the iPhone tap-through went from 6.5 % to 5.4 % and the Mac's from 0.5 % to 0.7 %. Sales: about 5 first downloads a day, 6 Pro units in 90 days.

## 2. Why so few downloads

1. **The big impression number is Mac search noise.** 75 % of impressions (88 % in September) are the Mac App Store showing a Developer Tools app for broad queries. Of those viewers, 0.7 % open the page. No creative change fixes relevance on the Mac, so the Mac number is not the target. The iPhone funnel is where the business is.
2. **The pitch is the category's commodity pitch.** "Send. Pocket it. Get pinged." / "Approve the risky command" / "When it asks, you answer" is what Happy (1,041 ratings), T3 Code, Paseo, Moshi, CC Pocket, Happier, Vicoa, Codex Relay and Claude Remote Control all say. Since February, Anthropic's own free Claude app also says it, with Remote Control in its Code tab. The pitch is also not how the heaviest user works: 1,388 of 1,391 bridge prompts ran with permissions bypassed, and in 91 days there were 6 Claude questions. The listing leads with an action its own power user almost never takes.
3. **The search card shows a wallpaper.** iPhone search results autoplay the preview muted, or show the first three panels. The preview spends its first 6 s on a Lock Screen wallpaper with one small Live Activity. Panel 1 is about 70 % wallpaper, and panel 3 is the onboarding form. A thumbnail of the card says neither "many agents" nor "your machines".
4. **No social proof.** There are 2 ratings in the US and 0 in GB, DE, FR and JP. Happy has 1,041, T3 has 160 and Paseo has 105. In this category that alone decides between two similar cards. The listing cannot fix it. See §7.
5. **Setup reads like homework.** The description's "WHAT YOU NEED … a Mac or Linux machine on your tailnet running one of your agents … three verified steps" is the first thing after the intro. The truth is better than the copy: one `curl … | bash` line that ends in a QR code, then a scan. No panel shows that.
6. **The keywords are wasted.** `lock screen`, `phone`, `usage`, `spend` and `widget` are words nobody types to find a coding-agent client. The promo text is empty on every live version.

## 3. How the app is really used (91 days, `scratchpad/usage-report.md`, numbers only)

- 7,348 prompts on 91 of 91 days, 81 a day, 1,172 sessions.
- An agent turn is running in 63 % of all clock hours, a median of 15 hours a day.
- Two or more turns run at once 30 % of the busy time. The median day peaks at 3, the record is 9 at once across two machines and seven repos, and 21 subagents ran at once.
- Turns run long: p90 22 min, 56 turns ran 3 hours or more, and one prompt ran 8.9 hours.
- Two machines: a Linux desktop with a 96 GB GPU, and a Mac. 59 % of days use both.
- Three agents: Claude Code 65 %, opencode 22 %, Oh My Pi 13 %. Models: Opus, Sonnet, Fable, DeepSeek, Grok and the opencode tiers. 10 % of prompts, and 38 % of opencode/omp traffic, go to models on the local GPU.
- Prompts are terse: a median of 54 characters. The most common message is `status?` (125 times), then `continue` (104) and `resume` (57).
- Only 36 % of conversations are software work. The rest are research, machine admin ("what is holding my GPU memory?"), hardware, gaming and media, asked of whichever machine and model fits.

**The story:** Tailscode is not a remote for one chat. It is the control room for a fleet of agents running on your own computers. They work for hours, several at once, on whatever model fits, including the one on your own graphics card, while you check in from anywhere.

## 4. What changes, and what stays

| Field | Decision |
|---|---|
| Name | **Stays** `Tailscode: Coding Agent Remote`. Third-party brands stay out of names (runbook `aso-and-growth.md`, 4.1(c) and 5.2.1). |
| Subtitle | **Stays** `Claude Code·opencode·Oh My Pi`. It is the app's only indexed "Claude Code", and naming all three agents is the house rule. |
| Promo text | **New**, every locale. It changes conversion only and is editable on a live version, so it can go out before the build. |
| Keywords | **Recut**, every locale. Drop `lock screen,phone,usage,spend,widget,approve,diff,git,quota`; add `local,ollama,gpu,ssh,terminal,cli,linux,parallel`. |
| Description | **Rewritten** around the fleet: one command, every agent at a glance, any model, long runs, not only code, cost, privacy. |
| What's New | 1.79's notes plus what landed after the tag: carry, the party, the Agents board. |
| iPhone panels | **New set**, ten panels, new masters, ten languages. |
| iPad, Mac panels | **New sets** on the same story. |
| Preview | **New** plain-footage take that opens on the Agents board. The poster frame is the board. |

## 5. Copy (en-US)

**Promo (165 characters)**: Run Claude Code, opencode and Oh My Pi on your own computers, on any model they can run, even your own GPU, and keep up with all of them from your phone. No sign-in.

**Promo, Mac (162)**: … and watch them all from one native window. No sign-in.

**Keywords, iPhone (98 bytes)**: `ai,llm,local,ollama,gpu,tailscale,tailnet,vibe,ssh,terminal,cli,homelab,linux,mac,omp,parallel,dev`

**Keywords, Mac (97 bytes)**: `ai,llm,local,ollama,gpu,tailscale,tailnet,vibe,ssh,terminal,cli,homelab,linux,omp,parallel,hotkey`

The description is canonical in `store/metadata/ios/version/1.79/en-US.json` and `store/metadata/macos/version/1.79/en-US.json`.

### iPhone panels (1320×2868, one lit phrase in **bold**)

| # | Slug | Master | Headline | Subline |
|---|---|---|---|---|
| 1 | 01-all-your-agents | `fl-agents` (Agents board, Now) | All your agents. **One pocket.** | Claude Code, opencode and Oh My Pi, working on your own computers. |
| 2 | 02-one-board | `07-home` (the ranked board) | Every machine, **one board** | Working, recent and done, across every computer you run. |
| 3 | 03-any-model | `fl-models` (models sheet, the GPU machine's tab) | Any model. **Even your own GPU.** | A cloud model or a local one on your machine, per chat. |
| 4 | 04-peek | `fl-peek` (the Peek over the board) | Look in on **any agent** | What it's doing now, its last steps and its helpers. |
| 5 | 05-one-command | `fl-setup` (Claude Code picked, the one-line install) | One line. **Then scan.** | Claude Code's bridge installs with one command. No sign-in. |
| 6 | 06-steer | `fl-steer` (a running chat, queue and stop in view) | Steer it **mid-run** | Queue the next message, or stop the turn on the server. |
| 7 | 07-ask-anything | `fl-gpu` (new demo chat on the GPU machine) | Ask your machines **anything** | Not only code: ask what's eating the GPU. |
| 8 | 08-carry | `fl-carry` (the model seam after a carry) | Switch models, **keep the thread** | The next model gets a short brief of the chat and carries on. |
| 9 | 09-party | `fl-party` (the party sheet) | Six models, **one swipe away** | A model and its effort in each slot. Swipe the pill to switch. |
| 10 | 10-costs | `14-analytics` | See what **it costs** | Every turn priced, every month totalled across machines. |

The Lock Screen panel was dropped: `shots.sh lock` drives Device Hub and cannot run over ssh, and the old master is one small card on a wallpaper, the weakness §2.3 names. Reshoot it at the Mac if it is wanted back. The first three panels are the search card, and together they say three things: many agents, on my machines, any model.

### iPad (2064×2752 portrait slot, landscape workspace masters)

1. All your agents. **One screen.** (`fl-agents`) 2. The last hour, **lane by lane** (`fl-hour`, iPad Hour) 3. Every step, **live** (`01-live`) 4. Any model. **Even your own GPU.** (`fl-models`) 5. Ask your machines **anything** (`fl-gpu`) 6. Approve with the **list in view** (`03-approval`) 7. Every quota, **on one screen** (`08-usage`) 8. See what **it costs** (`14-analytics`) 9. Long answers, **room to read** (`whole`) 10. Six models, **one tap away** (`fl-party`)

### Mac (2880×1800)

1. All your agents. **One window.** (agents window) 2. Two machines, **side by side** (`02-split`, the committed master) 3. Six models, **one click away** (party popover) 4. Switch models, **keep the thread** (carry seam) 5. **One chord** from anywhere (`04-quickask`) 6. Ask your machines **anything** (GPU chat) 7. The repo, **read, never operated** (`03-git`) 8. The month **in numbers** (`06-analytics`) 9. **Keyboard** first (`08-keyboard`) 10. Nothing leaves **your tailnet** (`10-private`)

## 6. Preview (plain footage, 886×1920, ≤30 s, IPHONE_67)

Driven by a new DEBUG `--fleet-tour` in `TourDriver`, recorded on a dedicated simulator, and cut with the existing `scripts/preview-video.py`. There are no captions, frames or overlays (runbook rule).

| Time | Beat |
|---|---|
| 0.0–5.5 s | The Agents board, Now: six agents across two machines, the needs-you card on top. Poster frame at 1.0 s. |
| 5.5–10 s | Tap a working agent and its Peek opens: the live step and the tail. |
| 10–16 s | Back to Home, open a chat, type a short task, send. The answer streams with tool runs. |
| 16–21 s | The model pill opens the party. Pick the local model's slot; the toast says what was taken. |
| 21–26 s | The GPU chat: the agent's `nvidia-smi` run and its answer table. |
| 26–30 s | The month in numbers. |

## 7. Outside the listing

- **"No analytics" is not true today, and it is live.** The 1.78 listing and the welcome screen (`Tailscode/Onboarding/WelcomeViewController.swift:85`, `:139`, "no analytics", "no telemetry") promise it, while `TailscodeMidgar.start()` configures MidgarSignals at launch (anonymous More Apps and purchase events) and the App Privacy label (`store/privacy-label.md`) declares Product Interaction for Analytics. The new copy says "no sign-in, no ads, no tracking, and your code and conversations never reach us", which is true either way. The product decision is Marcus's: either pass `enableTelemetry: false` in `Shared/Midgar/TailscodeMidgar.swift` and keep the promise, or change the two welcome strings. One of the two must happen before 1.79 ships, because the welcome screen is in the build.
- A fact-check of every claim against the source (`scratchpad/copy/factcheck.md` in the session) changed: setup is one line *for Claude Code*; a carry passes a *trimmed* brief; free means one *server* and one Live Activity at a time; Pro's badge is a heart in Settings; the Mac has no Home board (the sidebar is the board); an approval asks for Face ID *or the passcode*.

- **Ratings are the biggest lever left.** The prompt (`ReviewPromptPolicy`) asks after a second successful turn on a connected server, which is right. With about 40 active devices there is still almost nothing to ask. Worth considering once 1.79 is live: a Product Page Optimization test of the new set against the old, which needs no review, and Apple Ads exact-match on `claude code` and `opencode` once Pro proceeds per install clear the CPA gate.
- **Mac impressions:** do not chase them. If a cleaner Mac funnel matters, the lever is Mac keywords (done), not panels.

## 8. Shipping

Tailscode's registry policy is `metadata_edit = propose` and `release = manual-only`. Every write to App Store Connect therefore goes through Marcus at a terminal. This work prepares the files in `store/` (the `midgar` layout) and the preview MP4. The commands are in `store/README.md`. Nothing here creates a version, uploads, or submits.
