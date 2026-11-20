# Tailscode 2.0

Asked for (2026-11-20): should we start preparing Tailscode 2.0? Yes — the next release is a 2.0, and preparing it now costs little because the work is already built: 132 commits sit on master since the 1.83 builds that went live on iPhone, iPad and Mac on 14 November, and Experts lands on top of them. What is missing is a release, not features.

## Where it stands (Libra and App Store Connect, 2026-11-20)

- Live: 1.83 on iOS and macOS (14 Nov). In TestFlight only: 1.84 (iPhone and iPad 266, Mac 243). Linux runs master.
- Last 28 days: 117 first-time downloads (−28%), iPhone 60%, Mac 36%, iPad 4%; 74 installs opened it last week; ≈€45 from 3 sales; 4.2★ from 4 ratings.
- The iPad is 4% of downloads after a month of iPad work that has not shipped yet: the store has never seen the iPad workspace, two-thumb reach or the mini layouts.

## Why it is a 2.0

1. **Experts** — standing roles on your machine whose every task starts fresh with a brief and ends with a debrief you approve (`docs/experts.md`). Nobody else ships approved memory, guards and a proven device bench; it is the headline.
2. **The iPad is a workspace** — columns from what each needs, held-sideways thumb reach, the mini's own layouts, resize that redraws at once, Home and the chat list beside the conversation.
3. **One send moment on every client** — a courier that never loses a message sent offline; the answer stays closed until the prompt lands.
4. **Quiet at your desk** — the phone stays silent while you are at your computer, a read chat's notification comes down everywhere, the app icon counts news.
5. **Pictures the agent shows** — only the pictures named in the reply, in one strip, opening from where they are.
6. **Always ready on the desktop** — the quick ask chord answers with no window open on the Mac and Linux.
7. Smaller: Outer Rim, Megatron's head, page keys, folded long prompts, a Live Activity that keeps up past the first turn.

## Not in 2.0 (2.x)

From the November plan, still open and not started: pairing without Tailscale and an end-to-end relay (needs a decision on the tailnet-only principle), a web client served by the bridge, diffs/rewind/PR review on the phone, approvals 2.0, Siri App Schemas and Shortcuts automations. None of them blocks 2.0; each is a 2.x headline of its own.

## The release, end to end

1. **Experts done on all three clients**, reviewed, parity green, translated into all 16 languages; claude-bridge 1.37.0 released (every machine's updater installs it at a quiet moment); CodingAgentKit tagged and both `Kit.version` lines and `Package.resolved` files on that tag.
2. **One version line**: iPhone, iPad, Mac and Linux all say 2.0.0; the bridges keep their own versions and the app says which it needs.
3. **The funnel first** (`asc analytics`, Discovery & Engagement and Downloads by device and source): baseline and targets into `docs/marketing-2.0.md`.
4. **A current store set** for every device class — iPhone 6.9", iPad 13" (the workspace and Experts sideways), iPhone Duo (ten per locale), Mac — reshot from the demo world (which now holds three experts), framed with `frames`, captions in all 16 languages, a preview whose first frame is the product, the iOS 27 Header and Search Results creative, every claim fact-checked against the build.
5. **What's New** for each store from `git log` since that store's last release (iOS and Mac since 1.83), in every locale; GitHub release notes; the landing page (`midgarcorp.cc/tailscode`) leading with Experts.
6. **TestFlight, then review** on your word.

## Decisions that are yours

- The name: 2.0 for this release (recommended), or 1.85 and keep 2.0 for the relay.
- Whether Experts is part of Pro on the iPhone and Mac store builds (Linux and the direct Mac build gate nothing either way).
- When to submit.
