# Megatron in short

Asked for (2026-11-28): "can we improve megatron by having it look like a clean ui of what the bot is doing by summarizing it with a local LLM on each platform. this would be the your model optional thing stuff", with a look ahead: 3D models that run in that window, that a person names, "like a pet too, but that's the future". Same order as the other design docs: **look** (§1), **think** (§2), **design** (§3–§5), mocks in `docs/megatron-gist-mocks/`, then **implement** (§6). Capability `megatronInShort`.

## 1. What an open Megatron showed

Looked at on Linux (the screenshot the ask came with: a running turn of 354 steps, and the harness's demo turns settled and live), on the Mac (`--shot` of the demo) and on the phone (simulator).

- The right side of an open Megatron is the account: the agent's own notes in order with the work between them folded to lines. On a long turn that is 46 quotes, each restating the last, and the one line that says what is happening is `NOW Ran a command`.
- Nothing on the surface says what the turn is *for*, how far along it is, or where in 354 steps a thing happened. The head shows the shape of the work and the list shows every step; neither is a summary.
- The rules already say everything rules can: "Ran 267 commands, read 37 files, edited 4" is true and tells a person nothing they wanted to know.
- On the phone the open Megatron is five step rows and "170 more steps": the newest five tool calls.

## 2. What a model adds, and what it must never be trusted with

A model on the person's own machine reads the 46 notes in two seconds and writes what a person would: a title, a sentence, five stages. Measured on the real turn of 373 steps (Pennyroyal, Qwen 27B on SGLang): 5,100 prompt tokens, 1.6 to 2.4 s, and a telling that reads right. A 4B model answers too, worse: it names the agent, writes twelve stages and ends the last one at the wrong step. So:

1. **The model writes words and nothing else.** Every number a surface shows beside them is counted from the turn's own steps.
2. **Its answer is checked, not trusted.** A stage ends where an item of the account ends; stages rise and reach the last step; more than seven fold into their heavier neighbours; a sentence that names the agent loses the name; anything unreadable is no answer.
3. **No answer is today's Megatron.** Off, no model, a model that is asleep, a turn under ten steps, a failed request: the account is exactly as it was. Nothing depends on a model being there.
4. **It is the person's model on the person's network or it is not asked.** The same vetting plain words uses (`PlainModel.endpoint`), and never a model its server would have to load: whether it is in memory is read from the server first.
5. **It gets the account, not the transcript.** The notes and each run of work as its one line, secrets taken out; never reasoning, tool output or pictures. 373 steps are 19 KB.
6. **Words wear a mark.** `✦` and the theme's special ink mean a model the person runs wrote this, with who and where beside it.

## 3. The design

**In short** is a cover page for a turn (mocks: `megatron-gist-mocks/desktop.webp`, `phone.webp`; as built: `built-linux.webp`, `built-mac.webp`, `built-ios.webp`, `built-ios-stage.webp`).

- **Title**, small caps in the model's ink: what the whole turn is for.
- **Sentence**, the largest type a transcript sets (`TypeRole.lead`): what is happening at the end of what was read, or what a finished turn came to.
- **The step in flight** on one line under it while the turn runs: the rules' own `NOW` line, which is real time; the sentence is the gist and may be twenty seconds old.
- **The rail**: a stretch a stage, as long as its share of the steps, with a tick where an error was fixed and a taller one where it stayed.
- **A row a stage**: a check or the live dot, the model's few words, and the counts (errors left, errors fixed, lines written, steps).
- **What it changed**, once the turn settled.

A stage opens its part of the account, which is the account as it always was, scoped (`NeuralAccount.scoped`), with the cursor on the stage's first step so the list and the head show where it is. The way back is one press.

An error left in a stage is a count and a tick, never the stage's mark: the real turn has seven commands that exited non-zero and nobody re-ran, and a column of red marks said the turn had failed five times over.

## 4. When the model is asked (`NeuralGistDesk`, `NeuralGistPolicy`)

- Only while a surface is showing the turn, one request at a time across every turn, the turn asked for last first.
- A running turn again once it grew by six steps and eight times as long as the model took to answer has passed, never under twenty seconds: a model that takes thirty seconds is asked every four minutes.
- At once when the turn ends (the sentence changes tense) or work coming back wakes it.
- Stages told earlier that carry a fair share of the turn are shown to the model again so their words hold still while the story grows; light early stages are left out so they merge. Freezing every told stage was tried and rejected: seven tiny stages from the first forty steps stayed forever and the last one swallowed the rest.
- A telling is dropped the moment its turn has fewer steps than it was told at.
- Kept in memory for the 48 turns last shown; never written to disk.

## 5. Per client

| | Desk (Linux, Mac), wide | Desk, narrow account | Phone and iPad |
|---|---|---|---|
| Where | In the story's place, beside the head | Leads the account: title and sentence, the story under it | Where the step rows were, laid out for its height |
| Stages | Rows; arrows walk them, Enter opens | Not shown | Rows; a press opens the account sheet at that stage |
| Switch | Header: `✦ In short` / `Told 46`, and `i` | `i` | `Steps ›` in the title line, `‹ ✦ In short` above the steps |
| Inside a stage | Rail with the stage lit, `‹ In short`, `[` `]`, Esc | — | The sheet's heading: the model's words and what the turn counts there |

The switch (Tell each turn in short) is on the Your model page, on once a model is filed, with what the rules say of the demo's film turn beside what the model writes for it on Show me. The demo world carries a telling for its film turn (`NeuralGistDemo`), since no model answers there.

## 6. Implemented

- Core: `NeuralGist` (value, policy, setting), `NeuralGistAsk` (the log, the instruction, the reader), `NeuralGistDesk` (who, when, the seam for a check), `NeuralGistPane` (what a client draws, every word), `NeuralGistDemo` (the demo's telling, the page's sample), `NeuralAccount.scoped`, `TypeRole.lead`. 26 tests in `NeuralGistTests`.
- Linux: `BrainAccountGist.swift` (pins of the account), selftest group `account in short` (13 claims).
- Mac: `BrainAccountGist.swift` (`AccountGistView`, `AccountGistSwitch`), `BrainAccountChecks.short`.
- iOS: `BrainGistView`, the open view's slots, the reader's heading and scope.

## 6a. What it cost, and where the list starts (2026-11-28, second ask)

Asked for: "can megatron neatly show what everything it did cost in the user's local currency etc. the whole thing should localized anyway", and "maybe it should default to said only mode. it's quite clean, right?"

- **Cost.** A turn's price is its messages' prices summed, the answer's included (`NeuralTurn.costUSD`, set in `NeuralTurns.partition`), and it stands beside the counts in the account's header on every client and under the stages once the turn settled. A stage is priced only where the server priced every stage's messages. Looked at on the real turn: Claude Code prices a turn as one figure on one message, so the first stage said it cost everything and the others nothing; such a turn states its total and no stage's. opencode prices each message, so its stages are priced.
- **Currency.** Every such figure is an estimate priced in dollars, so the currency is presentation: `Money.estimate` converts at the European Central Bank's daily reference rate and writes the amount as the locale writes money. It is the one home (`SessionSpend.money` goes through it), so the status bar under a Megatron never says dollars while the Megatron says euros. The currency is the region's unless chosen (Currency, beside the answer's figures in Settings on all three clients): the desk this was written on is an English system in Finland, where the region says dollars. No table, a table ten days old, or a currency the bank does not quote, is dollars as they were always written. A balance a provider bills is never converted.
- **Said first.** The step list starts on what the agent said (`NeuralListStart`): it is the outline, and it is what the screenshot the first ask came with was already filtered to by hand. The SAID chip's last state is the start from then on, a turn in which nothing was said starts on every step, and the start is not a filter the header warns of. A stage puts the cursor on its first step the list is showing and never clears the start to do it.

## 7. What this leaves room for

The head's window is a stage with a character in it; the telling is what the character says. When a 3D model stands there with a name the person gave it, the sentence is its speech, the stages are its journey, the byline is its name, and `NeuralGistPane` already hands a client all three as plain values. Nothing here knows the head is a head.

## 8. Not built

- **The closed card's second line.** The first phone mock showed a running turn's card saying what is happening without being opened. That means asking the model for every running turn in every chat on screen, opened or not, which is a choice about a person's GPU rather than a layout, so it waits for a yes.
- A telling for a subagent's own steps, and one that outlives a restart.

## Mocks, and what looking at them changed

1. **Stage sentences were a line and a half on a phone.** "Built the bridge changes for sign-in and turns" does not fit beside its counts at 390 pt. The instruction now asks for three to seven words and at most 44 characters, which the model keeps to, and a phone's row shows a dot for errors and the bare step count.
2. **Chapters and story were taken.** Chapters are a conversation's titles and the account's column is "the story" in code, so this is a telling (`NeuralGist`) with stages, and a person reads "In short".
3. **Gold read as a warning.** The mocks drew the model's words in gold, which the themes spend on attention; built, they wear the special ink.
4. **`g` was Home.** The switch is `i`.
5. **Red marks lied.** See §3.
6. **A narrow account cannot hold a cover page.** Two panes side by side on the Mac left 180 pt for it; there the telling leads with its title and sentence and the story stays.
7. **The Now box pushed the stages off the pane.** In short it is one line.
8. **Two stages for a 29-step turn felt thin.** The fewest a turn is asked for is two to three, not two.
