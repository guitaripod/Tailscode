# Launch playbook

Working plan for the public launch + monetization of the Tailscode stack.
Not shipped to the App Store repo description — this file is the operator's checklist.

## Monetization (decided)

- Everything GPL-3.0 and public. The paid tier is convenience + support, never secrets.
- **Tailscode Pro** — one-time non-consumable, **$14.99**, Family Sharing on.
  `com.guitaripod.tailscode.pro`
- **Tip jar** — consumables $2.99 / $9.99 / $19.99:
  `com.guitaripod.tailscode.tip.small|medium|large`
- Reserved for a future hosted APNs push relay (the only subscription this audience
  accepts): `com.guitaripod.tailscode.relay.monthly|yearly`. Not shipped.
- Free tier is the complete core, forever: one server, full chat/permissions/
  attachments/models/fork/palette, one concurrent Live Activity, discovery scanning.
- Pro gates: 2nd+ saved server (Settings entry points + `ConnectionController.save`
  backstop), 2nd+ concurrent Live Activity (soft gate, never blocks a send),
  supporter badge. Alternate app icons later.
- Hard rules: never gate inside ChatViewController/ChatViewModel; nothing is
  deleted or disabled on entitlement lapse; the free tier always runs a full
  agent session.
- GitHub Sponsors on `guitaripod`; FUNDING.yml in all three repos; README-only,
  never linked in-app (App Review 3.1.1).

## Human-gated actions (in order)

1. **Rotate the opencode/bridge Basic-auth password** on arch + mac — the old one
   (`tailscode`) is in the public Tailscode repo's git history (scrubbed at HEAD)
   and on both hosts.
2. Enroll `guitaripod` in GitHub Sponsors (Sponsors dashboard, $5 tier, perk:
   priority triage + name in About).
3. Commit + push: Tailscode launch set, CodingAgentKit (tag next release after CI
   green, then submit to Swift Package Index), claude-bridge.
4. `gh repo edit guitaripod/claude-bridge --visibility public` after setting the
   repo description. Investigate the recurring claude-bridge crash reports on the
   mac (`~/Library/Logs/DiagnosticReports/Retired/claude-bridge-*.ips`) first.
5. ~~ASC: create the Tailscode app record + 4 IAPs (ids above); TestFlight via
   buildvm while this Mac is on beta macOS (ITMS-90111 rule).~~ **DONE
   2026-07-16** — app 6791660932, full listing + screenshots + review notes
   pushed via `scripts/asc-{setup,products,screenshots}.py`, build 1 uploaded
   via buildvm (vendored-Kit staging recipe in OPERATIONS.md). Submission
   still needs two web-UI clicks: App Privacy = "Data Not Collected", and
   ticking the 4 IAPs on the 1.0 version page so they ride the review
   (first-product rule) — then submit.

## Launch sequence

- **Day 0:** repos pushed, CI green, SPI submitted, Tailscale community catalog
  submission (kb/1531).
- **Show HN** (Tue–Thu, 9:00–12:00 ET):
  `Show HN: Tailscode – open-source native iOS client for Claude Code and opencode over Tailscale`
  First comment: why (turns finish while away from the desk), the stack (UIKit +
  Swift 6, GPL-3.0 Kit on Linux+Apple, claude-bridge structuring `claude -p`
  stream-json), one honest limitation (needs Tailscale + your own always-on
  machine). Canned answers: vs Anthropic Remote Control (Claude-only, one session,
  Anthropic-routed, closed) and vs "I just SSH/tmux" (Lock Screen Live Activities
  for approvals/completion, structured rendering).
- **+1 day, r/ClaudeAI:** `I built an open-source native iOS app for Claude Code —
  Live Activities on your Lock Screen, no relay server, just your tailnet`
- **+2 days, r/tailscale** + opencode Discord projects channel.
- **+3 days, Swift Forums Community Showcase:** CodingAgentKit post.
- **Saturday, r/iOSProgramming App Saturday:** engineering-insights framing
  (Live Activities, Swift 6 strict concurrency, streaming diffable data sources).
- **+2–4 weeks:** claude-bridge Show HN (after Docker + one-command install),
  r/selfhosted.
- Positioning everywhere: point-to-point over your tailnet, no relay, no VC, no
  tracking; differentiate vs Happy (RN + relay), Omnara (cloud), Remote Control
  (Claude-only, Anthropic-routed).

## Deferred

- Alternate app icons + picker (pre-TestFlight).
- Tailscode + claude-bridge CI, demo GIFs (simctl recordVideo → gifski; VHS for
  the bridge), Docker image.
- Relay subscription + Cloudflare Worker APNs push for walk-away Live Activity
  updates.
- Doc-comment pass on AgentCore, constant-time Basic-auth compare in the bridge.
