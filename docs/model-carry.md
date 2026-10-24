# Carry — one conversation, any model

Asked for: choose and switch to any model in a chat, every provider. Same order as the other design docs: **look** (§1), **design** (§2–§4), mocks in `docs/model-carry-mocks/`, then **implement** (§7).

## 1. What I looked at

The chooser, dial, presets and peek card are finished work; the picker is not the problem. Three things around it are:

- **A pick on another machine starts an empty chat.** `ModelFleet.moveBody`: "This chat stays where it is". Claude Code, opencode, omp and the local models are islands; the only thing that crosses is the model's name.
- **A fork cannot cut.** `forkSession` copies the whole session (the Kit's opencode 2.x fork sends an empty body, so no message id), so "ask this question again on another model" would carry the answer being retried.
- **The transcript never says where the model changed.** Every `ChatMessage` carries `providerID` and `modelID`; nothing draws the change. `ResponseStats` names the model under each turn, off by default and on every turn, not only where it changed.

## 2. Design

One verb, **carry**: the conversation goes with the person as text. Two entry points, one new row, no new picker.

| Piece | Where | New |
|---|---|---|
| **Continue on…** | a pick on another machine, from a chat | alert wording, one chip on the Home composer |
| **Try with another model…** | answer context menu → the same chooser | one menu item, `ChooserContext.branch` |
| **Seam** | transcript, where the answering model changed | one 24 pt line |
| **Carried line** | first row of a carried chat | one 24 pt line, opens the brief |

A pick on the *same* machine stays in place, as today. Only the seam is new there.

### The brief

Built on the device, once, when the pick is made. No model call, no server route, so it is instant, free, and the same bytes on every client and every backend.

```
<carried-conversation from="Fix reconnect test" kept="6" of="14" pictures="3">
Earlier: {compaction summary, or the brief this chat itself was carried with}
User: …
Assistant: …
Touched: Backoff.swift, ReconnectTests.swift
</carried-conversation>

{what the person typed}
```

- **Rides in the first message**, so it is durable in the transcript, identical on all three backends and visible on any device. A client splits it off with `CarryMark.split` and draws the line plus a bubble of what was typed. No `displayPrompt`, no synthetic part, no bridge change.
- **Budget** `min(0.4 × target window, 24k)` tokens, 12k when the catalog gives no window, estimated by `StatusFacts.estimateContextTokens`. Newest turns whole, oldest dropped whole; an earlier brief or compaction summary heads it, trimmed to half the budget. A newest turn that alone exceeds the budget is cut at it.
- **Content** is what the person and the model wrote: prose only. Tool output, reasoning and pictures stay behind (a secret a tool printed does not travel; the pictures are counted). Tool calls collapse to a `Touched:` line.
- The literal closing tag inside the text is written `<\/carried-conversation>`.
- **Wire contract**: the tag and its attributes are read by every installed app. Added to, never renamed.

### The seam

A settled answer whose **badge word** (`ModelBadge.word`) differs from the previous settled answer's draws `● Qwen Daily  from DeepSeek V4`: the model's tint dot, the new word, the old word in tertiary. Words, not ids, so `opus` against `claude-opus-4-8` never says "Opus → Opus"; effort alone never makes one; the first answer has none. A seam never crosses backends, because that is a carry.

Cost rule (a rebuild runs per streamed token): seams are memoised per settled message id; only the streaming message compares, against the last settled answer. `CarryMark` is looked at on the first user message only.

### Flows

**Continue on…** Pick on another machine → alert **"Continue on macbook?"** / "Qwen Daily runs on macbook. Your conversation comes with you as a short brief; this chat stays where it is." / **Continue there**. Today's two-button alert, new words. The Home composer opens aimed at that machine (`ComposerRetarget`, unchanged) with a chip `↩ Fix reconnect test · 6 of 14 ✕`; ✕ makes it a fresh chat. A chat with no settled turn has nothing to carry and keeps today's "New chat there".

**Try with another model…** Long-press an assistant answer → the chooser, whose every machine tab (this one too) says "A pick here branches this chat from that question on <machine>". The pick needs no alert, since the chooser said what it does. The Home composer opens aimed at the pick, the brief cut **before** the question, the field holding the question, unsent. The original chat is untouched, so the two answers sit in two chats a swipe apart.

**Carried line.** `↩ Continued from Fix reconnect test · 6 of 14`. The count appears only when something was dropped (an uncut carry just says where from). It wraps rather than truncates when it cannot fit. A tap opens the brief as text in the compaction reader. There is no link back to the original: the chat list already shows it.

## 3. Where it lives

- **Core** (new, no Kit change, no Kit tag): `ConversationBrief` (build, budget), `CarryMark` (wrap, split), `ModelSeam`. Edited: `ChooserContext.branch` + `ModelMachine.consequence`, `ModelFleet.moveTitle/moveBody/moveAction`, `ComposerRetarget` gains `carry` and `draft`.
- **Each client**: the seam row, the carried row, the chip, one menu item, the alert words. Nothing else.
- **Parity**: two capabilities, `modelSeam` and `carryChat` (both entry points). All three manifests answer `.implemented`, no gaps.

## 4. Rejected

- **A model-written summary.** It costs a turn and minutes (see `/compact`). The deterministic brief is instant; after a compaction its summary is reused anyway.
- **Native fork for the retry.** Cannot cut (§1), and a second path beside the carry.
- **A hidden prefix** (`displayPrompt`, opencode's synthetic part). Per backend, lost to another device's transcript.
- **A second picker or a per-message model.** The chooser already says what a pick does; "Try with" is a different context, not a different surface.
- **"Open original" on the carried line.** A profile id has no business in a message, and the list has the chat.

## 5. Not in this

Racing N models, an auto-router, failover along the pins, a price in the catalog, and Claude Code against other providers. Each can sit on top of carry; none is needed for it.

## 6. Mocks, and what looking at them changed

`carry-phone-dark.png` / `carry-phone-light.png`, one frame per piece.

- The carried line wrapped at "6 of 14 turns", orphaning the word. It now shows the count only when turns were dropped, without the unit (the reader says it), and wraps instead of truncating.
- The seam example crossed Claude and a local Qwen, which is a carry and could never be a seam. It is now two models one server runs.
- Dropped the "open original" link (§4).

## 7. Implement

Core first (brief, mark, seam, chooser context, tests), merged before the clients start; then iOS, Mac and Linux in parallel from specs that cite this doc. Core tests: the brief never exceeds its budget and keeps the newest turn; a compaction summary heads it; a mark survives wrap/split with hostile text in it; no seam for an alias against its resolved id; a rebuild after a streamed token does no work for settled messages.

Shipping: Linux `scripts/install-linuxapp.sh`, Mac `scripts/install-macapp.sh`; iOS cannot be installed from this machine and goes out with the next build. No bridge restart and no Kit tag.

The canvas version of this design is a private Claude artifact (https://claude.ai/artifact/8Pb9kgn8vsohss6V3cWJPZ). Its hero is one Blender render, `docs/model-carry-mocks/hero/`: `blender -b --factory-startup --python scene.py -- /abs/hero.png 2200 640 320`, then `python3 -I finish.py hero.png out.png` (glow, edge fade, grain) and a WebP encode. 18 KB, shown at 1100 px wide.
