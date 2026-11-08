# Dictation: speak into the box

Asked for on 2026-11-08, after someone tried T3 Code and found no built-in dictation: built-in dictation, made amazing on each platform, with its states, transitions and haptics designed. The order is the same as the other design docs: **look** (§1), **design** (§2–§9, mocks in `docs/dictation-mocks/`), **implement** (§11).

## 1. What I looked at

- **The composers.** iPhone and iPad: `ComposerView` (a glass bar: ＋, the words, a row with the model pill, and Send, which turns into Stop while a turn runs and the box is empty) and Home's `HomeComposerBar`. Mac: `ComposerView` over `PromptEditor` (vim, slash completion, the pills row). Linux: `ChatPaneComposer` over its own `PromptEditor`. Nothing in any of them listens.
- **What talks today.** The voice call is an ear for a chat, but it needs a 64 GB NVIDIA GPU on the server: on arch, while this was written, `voice-bridge` answered `busy` because llama-server held the GPU. So almost nobody can use it. The iPhone keyboard's microphone works in our box but writes `composer view dot swift` for `ComposerView.swift`. The Mac's system dictation (fn fn) works in `NSTextView` with the same problem. Linux has nothing.
- **What the others ship.** Claude Code's `/voice`: hold Space; audio goes to Anthropic, and it does not work over SSH or in remote sessions, because the microphone has to sit next to the CLI. Codex desktop: a microphone in the composer. Wispr Flow: hold Fn, double-tap to go hands-free, a start sound, paste on stop. Superwhisper: toggle or push-to-talk, with a waveform window. The common ground: a visible recording state with a live level, the words land in the box for review, Esc cancels, and permission problems are spelled out. The common complaints: a mic that silently does nothing, and Claude Code's tap mode, which sends by itself. A prompt here runs code on another machine.
- **Engines.**
  - **Apple:** `DictationTranscriber` (iOS and macOS 26). It runs on the device, takes `AnalysisContext.contextualStrings` (at most 100 phrases of one or two words), and offers punctuation, volatile results and frequent finalization. Its assets come through `AssetInventory`.
  - **Linux:** sherpa-onnx 2.0.1's C API with NVIDIA's Nemotron Speech Streaming 0.6B (int8, 160 ms chunks). Casing and punctuation are built in, and word error rate is 2.56% on LibriSpeech test-clean. Measured on arch: 1.4 s to load, real-time factor 0.44 on four threads, and partials arrive word by word ("After" → "After early" → "After early nightfall"…).

The point of difference writes itself. **The microphone is always on the device and the agent is always somewhere else.** That is exactly the case Claude Code's dictation refuses, and the case this app exists for.

## 2. Principles

1. **The box is the surface.** Words appear where you would have typed them, at the caret, as you speak. There is no overlay, no sheet and no second transcript. Words still being heard are lit in the accent; words the engine has settled dry into the box's own ink.
2. **One control, two hands.** Tap the microphone and talk hands-free until you tap again. Press and hold it to talk while you hold. While holding, slide away to cancel, or onto Send to send. The keyboard chord does the same thing: tap toggles, hold talks.
3. **The first word is never lost.** The microphone opens on touch-down, not touch-up, and audio is buffered from the first millisecond while the engine wakes.
4. **It knows the project's words.** File names, the branch, identifiers and commands from the chat bias the engine and snap spoken forms to written ones.
5. **It never sends by itself.** Dictated words wait in the box. Sending is always an act: Send, ⏎, or a deliberate slide onto Send.
6. **Nothing leaves the device.** Apple's engine and the Linux model run locally. The server never hears you.
7. **Every state looks different and says what is true.** A mic that cannot work says why and offers the fix. Stillness means settled; motion means the microphone is open.

## 3. States

One state machine in Core (`DictationPhase`), drawn by every client from one face (`DictationFace`) and one set of words (`DictationReading`).

| State | Meaning | The microphone control | The box | The hint line |
|---|---|---|---|---|
| **Hidden** | Cannot exist here: iOS below 26, the delegate packet ("a packet is written, not dictated"), or a live call on this chat (the call is already listening) | absent | as ever | — |
| **Ready** | Can listen | `mic`, secondary ink | as ever | — |
| **Needs a model** | Apple's assets for the language are not installed, or Linux has no speech model yet | `mic` with a small ↓ badge | as ever | — |
| **Getting ready** | Assets or model downloading | a determinate ring around the mic | as ever | *Getting dictation ready · 34%* |
| **Waking** | Touch is down; audio is buffering while the engine loads (≤ ~0.4 s warm, ~1.5 s cold on Linux) | the capsule, already lit | edge sweeps in | *Listening…* (placeholder if empty) |
| **Listening, hands-free** | Mic open until tapped | the capsule: accent fill, five level bars | edge lit and breathing with your voice; heard words in accent, settled in ink | *0:12 · Tap to stop* |
| **Listening, held** | Mic open while held | the capsule, slightly larger under the finger | same | *‹ Slide to cancel*; Send glows faintly as a drop target |
| **Release to cancel** | Held and slid far enough left | the capsule in the danger tone | this take's words dimmed and struck | *Release to cancel* (danger) |
| **Release to send** | Held and slid onto Send | the capsule shrinks toward Send | same | Send ringed and enlarged; *Release to send* |
| **Settling** | Stopped; waiting for the last words to settle (≤ 1.2 s) | bars collapse into the mic | edge fades; the lit tail dries | — |
| **Discarded** | A take was cancelled | `mic` | the box as it was before the take | *Discarded · Undo* (5 s) |
| **Nothing heard** | The take ended with no words | `mic` | as it was | *Didn't hear anything* (3 s) |
| **Can't hear you** | Microphone access is off, or no microphone answers | `mic.slash` | as ever | Press: a sheet (phone) or popover (desktop) that says which and offers the fix |
| **Taken** | Something else took the microphone mid-take (a phone call, Siri, an unplugged headset, another app) | `mic` | words kept | *The microphone was taken. Your words are kept.* (warning, 4 s) |
| **Stopped** | The engine failed mid-take | `mic` | words kept | *Dictation stopped. Your words are kept.* (warning, 4 s) |
| **Time's up** | A take reached 10 minutes; warned at 9:30 | `mic` | words kept | *Stopped at 10 minutes. Your words are kept.* |

A take means one press, from opening to closing.

## 4. Transitions

| From → to | Trigger | Motion | Feel |
|---|---|---|---|
| Ready → Waking | touch-down / chord down | The mic glyph widens into the capsule (34 → 56 pt, spring 0.32 s, damping 0.7) as the glyph crossfades into the bars. The edge draws itself from the mic round the box (conic sweep, 360 ms ease-out), then settles to breathing | `listen` |
| Ready → Can't hear you | press while access is off or no microphone answers | The sheet (phone) or popover (desktop) rises with the fix | `warning` |
| Waking → Listening | first audio reaches the engine | none: it already looks like listening | — |
| Listening, any | each meter tick | The bars follow the level smoothed by `VoiceCallLevels` (40 ms attack, 220 ms release). Edge opacity is 0.45 + 0.55 × level | — |
| Heard → settled word | a final result | The lit words crossfade to ink (180 ms) | — |
| Touch-down → held | still down at 280 ms | *‹ Slide to cancel* fades in above the box | — |
| Touch-down → hands-free | lifted before 280 ms | *0:00 · Tap to stop* fades in | — |
| Held → Release to cancel | slid ≥ 72 pt left (desktop: 60 px) | The capsule tints danger (150 ms) and the take's words dim | `notch` |
| Held → Release to send | the finger enters Send's frame (+12 pt slop) | Send scales to 1.15 with an accent ring | `notch` |
| Either armed → held | slid back | reverses | `selection` |
| Listening → Settling | tap the capsule, release, the chord again, Send or ⏎ | The bars collapse to a dot that becomes the mic (220 ms). The edge fades (300 ms) | `listenEnd` |
| Release to cancel → Discarded | release | The take's words fade out (200 ms); the box returns to how it was | `tap` |
| Release to send → sent | release | Settles, then sends through the composer's own path (queue while busy) | `send` |
| any → Taken / Stopped | interruption or failure | One flash of the edge in the warning tone, then out | `warning` |
| Needs a model → Getting ready | press | The ring draws from 0 | `tap` |
| Getting ready → Ready | done | The ring closes, then the mic does one 1.0 → 1.08 → 1.0 pulse. It does not listen on its own: a microphone that opens without a press is a surprise | `success` |

**Reduced Motion** drops the sweep, the springs and the pulse, and keeps crossfades. The level bars stay, because they are information, not decoration. **VoiceOver** hears *Listening* when the mic opens, *Added 14 words* when the take ends, and nothing in between. Live words are not announced, because a word that changes four times would be read four times.

## 5. Haptics

The phone is in the hand while you dictate, so a cue is felt, not looked for. There are two new cues in `HapticCue`, both in the *Touch* group so they are listed and scaled like every other cue:

- **`listen`, "Listening".** The microphone opens. A crisp transient (0.55 intensity, 0.45 sharpness) blooming into a short soft body (70 ms, 0.32, 0.15): a click that opens.
- **`listenEnd`, "Listening ends".** Your words settle. A soft body (60 ms, 0.30, 0.10) closed by a lighter transient at 50 ms (0.42, 0.25, floor 0.2): the inverse of the open, so the two read as a pair.

Existing cues cover the rest: `notch` when an arm is crossed, `selection` when it is left, `tap` on a cancel, `send` on release-to-send, `warning` when the mic is taken, `success` when a model lands. There is no cue per word (that would be a rattle) and none for loudness. The Mac plays `NSHapticFeedbackManager` `.levelChange` on open and close, and `.alignment` when an arm is crossed with the button held, which is felt only on a Force Touch trackpad. Linux has no haptics. On the desktops the eyes are on the box, and the box's light carries it.

There are no earcons. A start sound would be recorded into the take it announces, and the box lights up within the same frame.

## 6. Words from the chat

When the mic opens, `DictationVocabulary` is built once from at most the last 40 transcript items, never the whole conversation:

- the project folder's name and the branch;
- the file names the agent read, edited or wrote (basename and stem);
- code-shaped identifiers in the last messages (CamelCase, snake_case, dotted, containing digits);
- the server's slash commands;
- the names on the model pill.

Terms are ranked by recency and capped. Apple's `AnalysisContext` gets at most 100 phrases of one or two words. The shaper gets up to 300.

`DictationShaper` runs on every result, heard and settled, so a word never flickers between two spellings, and it works for every engine:

- **Commands.** *slash compact* at the start of the box becomes `/compact` when the chat offers that command.
- **Snapping.** A run of one to five spoken words whose letters match a term's become the term as written. Matching reads *dot* as `.`, *underscore* as `_`, *dash* as `-`, *slash* as `/`, and ignores case and spaces: *composer view dot swift* or *Composer View.swift* becomes `ComposerView.swift`.
- Spoken punctuation is left to the engines: Apple's punctuation option and Nemotron's built-in casing and punctuation.

Settings has one switch for it, **Words from the chat**, which is on by default.

## 7. Where the words go

- At the caret, replacing any selection. A space is added when the character before needs one. The first word is capitalised at the start of the box or after a sentence end, when the engine did not.
- The whole take is one undo step, *Undo Dictation*. A cancelled take can be brought back with *Undo* on the hint, or ⌘Z / ⌃Z / shake.
- **Typing while listening** stops listening, keeps what is shown, and lets the keystroke land.
- **Send or ⏎ while listening** stops, settles (≤ 1.2 s), then sends. While a turn runs it queues, as typed words do.
- **Leaving the chat**, backgrounding the app or locking the screen stops and keeps the words. The draft store already keeps the box.
- **One take per process** (`DictationDesk`). Starting one in another pane or window stops the first, which keeps its words. Starting a voice call stops a take first.
- In vim's normal mode the words still go in at the caret, and the mode is left as it was.

## 8. Each platform

**iPhone and iPad.** The mic sits just left of Send in the composer's bottom row: a borderless glyph in secondary ink with a 44 pt target. Listening, it grows into a 56 × 34 pt capsule in the accent with five level bars in on-accent ink, wearing a soft halo whose radius follows your voice. A circle would read as a second Send. The box's glass gets a 1.5 pt accent edge. The hint capsule floats 8 pt above the box, centred: glass with a small accent dot that breathes while listening, then the words. The settled words are `label`; the heard tail is the accent at 85%. Home's composer and the chat's share one `DictationController`. An iPad with a keyboard uses ⌃⇧D: tap toggles, hold talks, Esc cancels, ⏎ stops and sends.

**Mac.** A borderless `mic` button sits left of Send, with a tooltip of *Dictate (⌃⇧D): click to talk, hold to talk while held*. Listening, `PromptEditor`'s resting border becomes the lit edge, the ultracode aura parks, and the button becomes the capsule. Holding the button with the mouse and dragging left past 60 px arms cancel, so the gesture is the same as the phone's. The chord ⌃⇧D comes from the shared registry and is rebindable. Esc cancels, and ⏎ stops and sends (respecting send-on-Return). **Chat ▸ Dictate** carries the chord in the menu bar. The hint is the same capsule, drawn as a small glass label above the editor.

**Linux.** A flat circular `audio-input-microphone-symbolic` button sits left of Send. Listening, the composer frame takes the `.listening` CSS class (accent border, `box-shadow` glow keyed to the level by a tick callback that reads one number), and the button draws four bars in a `GtkDrawingArea`. ⌃⇧D, Esc and ⏎ work as on the Mac. **The first press downloads the model:** a popover from the mic reads *Dictation runs on this computer · Speech model, English · 474 MB, once · NVIDIA Open Model License* with **Download**. While downloading, a bar reads *212 MB of 474 MB · 40 s left* with **Cancel**. After that it reads *Ready. Click, or hold ⌃⇧D, to talk*. There are no toasts and no command to paste. A machine without a microphone gets the button dimmed, with the tooltip *No microphone answers*.

**Settings** (iOS: Chat ▸ Dictation; Mac: Preferences ▸ Chat; Linux: Settings ▸ Chat):

- **Language:** Automatic, or one of the engine's languages. On iOS, Automatic means the keyboard's language; on the Mac, the first preferred language. On Linux it reads *English* (the model's only language) with a footnote.
- **Words from the chat** (on).
- **Linux only:** *Speech model · 474 MB on disk · Remove*.

The chord is on the keyboard page with every other shortcut.

## 9. Engines

**Apple** (`AppleDictationRecognizer`, `@available(iOS 26, macOS 26, *)`):

- **Transcriber:** `DictationTranscriber(locale:contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])`. This is long-form: there is no `shortForm` hint, because a prompt can ramble for minutes. Frequent finalization makes the ink dry sooner.
- **Locale** is resolved with `supportedLocale(equivalentTo:)`. Assets come from `AssetInventory.reserve(locale:)` plus `assetInstallationRequest(supporting:)` and `downloadAndInstall()`, with its `progress` driving the ring.
- **Audio:** the microphone is `AppleVoiceIO`'s capture (24 kHz PCM16 mono, voice processing on, interruptions and route changes already handled), converted with `AVAudioConverter` into `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
- **Retention** is `.lingering`, so a second take wakes fast. Volatile results replace the tail; a final appends and clears it.
- **Stopping** finishes the input and calls `finalizeAndFinishThroughEndOfInput()`. Cancelling calls `cancelAndFinishNow()`.
- **Permission** is the microphone only. `NSSpeechRecognitionUsageDescription` is also in the Info.plist as a guard.

**Linux** (`SherpaDictationRecognizer`):

- **Engine:** sherpa-onnx 2.0.1's shared C library: x64 `linux-x64-shared-no-tts-lib` (9.4 MB), arm64 `linux-aarch64-shared-cpu-lib` (12.5 MB).
- **Model:** Nemotron Speech Streaming en 0.6B int8, 160 ms (464 MB).
- **Download and install:** both come from k2-fsa's GitHub releases, pinned to GitHub's own SHA-256 digests, and are unpacked into `~/.local/share/tailscode/dictation/<pack>`.
- **Loading:** a C shim compiled against the vendored `c-api.h` loads them with `dlopen`, so no build, Flatpak or package depends on them.
- **Decoding:** greedy search with endpoints on (rule 2: 1.0 s of trailing silence, so a sentence is one final). PCM16 24 kHz is resampled to 16 kHz float.
- **Lifetime:** the recognizer stays loaded five minutes after the last take, then lets go of its ~700 MB.
- **Audio:** the microphone is `PulseVoiceIO`'s capture.
- **No hotwords:** they need beam search and a `bpe.vocab` this model does not ship, so the shaper carries the vocabulary.

## 10. Not in this

- Voice commands (*delete that*, *send it*).
- A server-side engine.
- Languages other than English on Linux.
- Hotwords on Linux.
- A global hotkey outside the app.
- Dictation into the delegate packet.
- Sending by itself.
- Earcons.

## 11. Implement

1. **Core** (`TailscodeCore/Sources/TailscodeCore/Dictation/`), with tests:
   - `DictationPhase` / `DictationSnapshot` / `DictationFace` / `DictationReading`;
   - `DictationSession` (an actor over a `VoiceAudioCapture` and a `DictationRecognizer`, buffering until the engine is ready);
   - `DictationDesk`, `DictationGesture` (tap/hold/slide thresholds), `DictationInsertion`, `DictationVocabulary`, `DictationShaper`, `DictationPreferences`;
   - `DictationDemo` (a scripted recognizer for `--demo`, screenshots and selftests) and `AppleDictationRecognizer`;
   - the cues `listen` and `listenEnd`; `KeyAction.dictate` with `composer.dictate` (⌃⇧D);
   - `AppCapability.dictation`.
2. **Linux:** the `CSherpa` shim, `SherpaDictationRecognizer`, `DictationModelStore` (download, verify, unpack, remove), the button, edge, popover and settings row, and the selftest.
3. **iPhone and iPad:** `DictationButton`, `DictationController`, the edge and the hint capsule in `ComposerView` and `HomeComposerBar`, keyboard chord and settings rows.
4. **Mac:** the button, the `PromptEditor` edge, the hint, the chord and menu item, settings, and the selftest.
5. Parity answered on all three, strings in eleven languages, Linux installed, iPhone and Mac to TestFlight.

## 12. Mocks, and what looking at them changed

`phone.png` (eight iPhone states), `desktop.png` (the Mac listening from the chord, Linux's first press), `states.png` (the machine, its transitions and the two new cues), each with a `-light` twin; `render.sh` renders them.

- The listening control was a 34 pt circle. Beside the blue Send it read as a second Send in every listening state (figures 2, 3 and 5). It is now a 56 × 34 capsule with five bars that the mic grows into, so the shape says "this is your voice" and Send stays the only circle.
- Linux's popover first floated over the transcript, with its arrow on the words. A GTK popover points at the widget that opened it, so it now sits on the mic and covers the box while it is open, which is fine for something open only while downloading.
- *Can't hear you* was drawn as a state of its own at the top of the machine, and its line crossed the download states. It is reached from Ready by a press while access is off, so it now hangs off Ready, and that press gets the `warning` cue, which §4 had missed.
- Release-to-send scales Send to 1.15 with a ring that overflows the glass. On iOS, Send is the composer's subview, not the glass's, so nothing clips it. On the Mac the ring is drawn by the button's own layer with `masksToBounds` off.
