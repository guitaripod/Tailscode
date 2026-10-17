# Range — a trip computer instead of a fuel gauge

Scope: how the app tells a person what they have left to spend. Today every client answers one question, *how full is it?*; this answers the one a driver actually asks, *will I make it?* Three tanks are covered — the conversation's context window, the account's quota windows, a prepaid balance — plus the one hidden variable that decides what the next send costs, the prompt cache. Presentation and arithmetic only: no turn is ever sent, compacted or re-routed on the person's behalf. Mocks: `docs/range-mocks/pace.png`, `chat.png`, `away.png` (sources and `render.sh` beside them; numbers in them are illustrative).

## Look

Read from the code on 2026-10-17; nothing here comes from a measurement.

- **Every surface is a level.** `ContextFill` states a share and a tone at fixed 50% / 80% (`attentionAt`, `dangerAt`); `QuotaSurface.Pressure` states a tone at fixed 60% / 85%. 62% of a five-hour window with 2h 47m left, 62% with 4h 48m left and 62% of a context window are the same amber bar, though one of them is a wall in 82 minutes and one is a fine morning.
- **The data for pace is already there and unused.** A `UsageQuota.Gauge` carries `fraction` and `resetsAt`; the window's length is in its key and label (`five_hour`, "5-hour session", "Weekly · all models", opencode's `weekly`, Grok's "Weekly credits"). Elapsed share is one subtraction and a landing point one division. The weekly reset is **not trusted** (`trustedReset: kind == "session"` in claude-bridge `Usage.swift`), so a weekly projection must say *about*.
- **The compaction advice has no clock and no cost.** At ≥ 50% the panel says "Getting fuller. Compacting trades the transcript for a summary and frees most of it" — it does not say how many turns remain, which read is eating the room, or what the next send will cost.
- **The prompt cache appears nowhere.** It is the largest single multiplier on what a turn costs, a pause past its lifetime makes the next send re-read the whole conversation at full price, and the CLI states each write's lifetime: this machine's own transcripts carry `cache_creation.ephemeral_1h_input_tokens` and zero `ephemeral_5m` — **one hour**, not the five minutes a hard-coded countdown would have assumed.
- **Three tanks, three homes, no answer to "which first?"** Context lives in the facts-row chip and its sheet, quota in the usage board and Home's strip, money in the spend sheet. Nothing says which will run out first, or whether it will before the next refill.

## Think

A gauge tells the level. A trip computer tells the range, and a car has seven more instruments a driver would miss:

| Car | Here | Comes from |
|---|---|---|
| Fuel level | fill | exists |
| Distance to empty | turns left (context), wall time (window) | burn rate from the transcript; pace from the window |
| The next station | reset time; a compaction | known |
| *Will I make it to the station* | slack = reset − wall | new, and the one that matters |
| Cold start | cache lapse: next send re-reads everything | CLI cache TTL + last activity |
| What is in the boot | the window by content: tool output, answers, you | transcript, scaled to the measured total |
| Trip meter | footprint per turn, compactions as pit stops | transcript |
| Low-fuel lamp, early enough to act on | one notification | pace |

Principles:

1. **Range, not level.** Where a level is all there is (no clock, no history) it stays a level; where a pace exists the words are the distance left.
2. **Quiet until there is news.** A fuel gauge is calm and the lamp has a reason. A row on pace is exactly as tall as today's; a line of words, a chip, a notice appears only when the pace says the tank will not last.
3. **A projection is never stated as a fact.** It needs signal (window ≥ 10% and ≥ 15 min elapsed, ≥ 2% used; ≥ 3 turns since a compaction), says its basis ("at the last five turns' pace"), says *about* when the reset is estimated, is recomputed on every reading and never stored as if it had happened. No signal says so ("Too early to tell the pace"), never a number.
4. **One grammar.** Solid fill = used. Tick = where an even burn would be by now (time elapsed on the same 0–100% axis). Hatched tail = where the fill lands if nothing changes. A reader compares the tick with the **fill** (ahead of or behind pace) and reads the tail alone (where it lands); they are not compared with each other.
5. **Tone follows landing, not level.** A window is amber when its tail reaches the limit before the reset by at least `max(10 min, 10% of what remains)` — a wall three minutes before the reset is not news — and red only when it is a wall. 90% with ten minutes to go is fine; 50% on day two is the story.
6. **Glance surfaces draw news; opened surfaces draw everything.** Home's strip, the widgets and the Lock Screen draw a tail only when it is news; the usage board and the sheet always draw it.
7. **Every fact has one home, and the chip keeps its meaning.** The context chip is always the context; a quota gets its own chip only while it will run out first. Both open one sheet.
8. **It reads, it never operates** (the git doctrine). It does not compact, switch models or hold a send. Compact still goes through its preflight; a better model is mentioned, never selected.
9. **A change of verdict is announced once** (one pass of light, nothing under reduced motion, like `BetaSheen`); everything else holds perfectly still, because a standing fact is not an activity.

## Design

### Core (toolkit-free, never `@MainActor`)

- **`QuotaPace`**: `read(gauge:now:)` → span (from `Gauge.windowSeconds` once the bridge sends it, else parsed from key/label by the same word-list approach as `QuotaBinding`; unknown span = no pace, today's bar), `elapsed`, `landing = used / elapsed`, `wallAt` (now + (1 − used) / rate), `slack = reset − wallAt`, `approximate` (untrusted reset), and `verdict`: `.onPace` (< 85%), `.closeToTheLine` (85–100%), `.willRunOut(at:)`, `.wall`. `basis` is `.sinceStart`, or `.recent(hours)` once `QuotaTrail` exists.
- **`ContextBurn`**: footprints after each assistant message since the last compaction seam; `turnsLeft = remaining / mean growth` over the last five turns, stated as *about N* and only from 50% full with three turns of history; `biggestAddition` (the largest single step of the epoch) as a share of what is left. Compaction resets the epoch. A server with no per-message footprint reads the estimate and says nothing about turns.
- **`CacheWarmth`**: `.warm(remaining)` / `.cold(since)` from the last assistant `completedAt`, the TTL the bridge read from the CLI, and now; the cost of cold is the footprint **in tokens, never money** (the `SwitchCost` rule). No TTL, no row (opencode).
- **`ContextComposition`**: parts grouped as system & tools, you, answers, tool output (per tool), images; character-count estimates **scaled so the shares sum exactly to the measured footprint**, always marked as estimates of a measured total; the largest items carry their message id so a tap scrolls to them.
- **`RangeBoard`**: for one conversation, the context tank, every window `QuotaBinding.governs` for the model on the next send (the others listed dimmed as *not this model*, with what would happen if you switched), and the cache; `earliest` is the first to run out. For the account: every provider's windows. `RangeReading` writes the words (headline, chip texts, the notification, the widget sub-line) in one place, as `ContextFill` and `QuotaSurface` already do.
- **`QuotaTrail`** (phase 3): device-local samples per gauge (`tailscode.quotaTrail`, `SettingsFile` prefix on Linux), coalesced to one per five minutes for seven days. Gives `.recent` pace — a week's average hides a bursty Monday.

### Wire (small, additive, optional — an older server just gets less)

- claude-bridge / omp-bridge: `windowSeconds` on each gauge; the cache TTL on the message's context (`3600` or `300`, from `cache_creation`). The context window needs nothing: the Kit's own Claude table already states 1M for `fable`, `opus` and `sonnet`, and `ContextWindow.fromCatalog` matches an alias inside a dated id.
- Kit: `UsageQuota.Gauge.windowSeconds: TimeInterval?` (decodes absent), `ChatMessage.cacheTTL: TimeInterval?`.
- Phase 4: the bridge keeps the trail (`GET /usage/trail`), because a quota is the account's and every desk should agree on its pace — the same reasoning as session marks.

### Surfaces

- **Chat facts row**: unchanged while there is room. Context news: the ring keeps the fill, the words become `~8 turns`. Quota news: one clock chip `Wall 19:22` (`Wall Fri 13:00` beyond twelve hours), only while a window that governs this chat's model will run out before its reset. Cache: a quiet `Cache cold` chip once an idle chat outlives its cache, gone after the next send. Full: unchanged.
- **The Range sheet** (replaces the Context sheet and the desktops' context panel; `.contextWindow` stays as the capability that feeds its first section): a one-sentence verdict naming the earliest tank; the governing tanks as pace bars with their one line of news; the cache as one row that grows into a sentence only inside ten minutes or once lapsed; what is in the window (content, with a switch to the existing billing tiers) and its three largest items; footprint per turn with compactions as pit stops and the next three turns hatched; Compact… through its preflight; the provenance footer. A sheet on iOS, a popover on the Mac, `ContextPanel`'s dialog on Linux.
- **Usage board**: pace bars in every row (the shipped two-line anatomy, plus tick and tail, plus one line of words only when it is news). The lead's pill is the verdict (*On pace / Mind the pace / Will run out / Used up*) where a pace exists and today's `Pressure` where it does not. Order is still the person's; only `tightestFirst` ranks, and ranks walls first, then the earliest projected wall, then the existing tightest.
- **Home**: the summary line under `HomeStatus` speaks only for the earliest window that will run out before its reset; the strip keeps every provider and its order, gains the tick, and draws a tail only as news.
- **Widgets and Lock Screen**: `WidgetGlance` gains the tick and a sub-line carrying the wall time instead of the reset when there is one; a snapshot nobody could refresh still says so first.
- **One notification**, *Running low*: plain category, no buttons, once per window per crossing, re-armed only after the projection has stayed under 90% for a while; account-wide windows only; opens the sheet. A switch under Settings ▸ Notifications.
- Not here: a Live Activity (a turn's card says what the turn did; the range belongs to the conversation), sound, any efficiency score.

### Degrading honestly

| Reading | When it is missing |
|---|---|
| Pace | window span or reset unknown → today's bar, no tick |
| Weekly pace | reset untrusted → dashed tick, *about* |
| Turns left | < 3 turns, < 50% full, or no per-message footprint → level only |
| Cache | no TTL (opencode) → no row |
| Composition | no transcript on this device → hidden, never a guess |
| Money | local models read *Free*, per the analytics doctrine |

### Parity

New `AppCapability.range` (area `status`). iOS, Mac and Linux each answer it; chips, sheet and board in phase 1 on all three, widgets and Lock Screen `.notApplicable` on the desktops, the notification `.implemented` on iOS and `.partial` on desktops until phase 3.

## Order of work

1. **Core pace math + tests** (`QuotaPace`, `ContextBurn`, `RangeBoard`, `RangeReading`), then chips, sheet and board on the three clients in parallel from specs that cite this document. No wire change.
2. **Cache and composition**: Kit fields, bridge forwarding, `CacheWarmth`, `ContextComposition`.
3. **`QuotaTrail`, the notification, the widget tick.**
4. **Server-held trail** (cross-repo).

Tests that prove it: pace arithmetic as a table (the numbers in the mocks included), every gate above as a negative case, an on-pace row that stays exactly two lines, composition shares summing to the measured footprint, `ContextBurn` resetting at a seam, and a verdict that wobbles around a threshold never ringing twice.

## Mocks, and what looking at them changed

- **A quiet tail is noise.** The first board mock drew a tail on every row. Where nothing is wrong, fill + tick + tail made three marks per row, and the tail's end sat beside the tick as if the two were related. Decision: glance surfaces (Home, widgets, Lock Screen) draw a tail only when it is news; the board and the sheet keep it, and the legend says the tick is read against the fill.
- **The sheet was 1.6 screens, with the cache a three-line card.** The first screen holds the verdict and the governing tanks, which is the point; the cache became one row, a sentence only when it matters.
- **A scoped window does not belong in another model's chat.** The Opus row is dimmed *not this model* with what switching would mean, from `QuotaBinding.governs` — otherwise a Sonnet chat's verdict would be about a wall it cannot hit.
- **The cache line carries tokens, not dollars** (the switching-cost rule), which also keeps the sheet free of a second money figure to argue with the spend sheet.
- Fixed in the mocks, nothing to do with the design: the anatomy's labels collided, and the widget ring lost its figure to a CSS mask over the whole element (the same trap the usage remaster hit).

## Open for Marcus

- *Running low*: on by default for account-wide windows (the mock), or off until asked?
- Phase 4 puts the trail on the bridges. Worth the cross-repo change, or is a per-device pace enough?
- The sheet's name: *Range* (the car's word, used here) or *Pace*.
