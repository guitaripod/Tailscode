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

| State | Meaning | The microphone control | The box | The status line (inside the box, §14) |
|---|---|---|---|---|
| **Hidden** | Cannot exist here: iOS below 26, the delegate packet ("a packet is written, not dictated"), or a live call on this chat (the call is already listening) | absent | as ever | — |
| **Ready** | Can listen | `mic`, secondary ink | as ever | — |
| **Needs a model** | Apple's assets for the language are not installed, or Linux has no speech model yet | `mic` with a small ↓ badge | as ever | — |
| **Getting ready** | Assets or model downloading | a determinate ring around the mic | as ever | *Getting dictation ready · 34%* |
| **Waking** | Touch is down; audio is buffering while the engine loads (≤ ~0.4 s warm, ~1.5 s cold on Linux) | the capsule, already lit | edge sweeps in | *Listening…* (placeholder if empty) |
| **Listening, hands-free** | Mic open until tapped | the capsule: accent fill, five level bars | edge lit and breathing with your voice; heard words in accent, settled in ink | *0:12 · Tap to stop* |
| **Listening, held** | Mic open while held | the capsule, lifted to 1.08 under the finger | same | *Release to keep · ‹ slide to cancel* (a chord hold: *Release to keep · esc cancels*); Send glows faintly as a drop target |
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
| Ready → Waking | touch-down / chord down | The mic glyph widens into the capsule (34 → 56 pt, spring 0.32 s, damping 0.75) as the glyph crossfades into the bars. The edge draws itself from the mic round the box (conic sweep, 360 ms ease-out), then settles to breathing | `listen` |
| Ready → Can't hear you | press while access is off or no microphone answers | The sheet (phone) or popover (desktop) rises with the fix | `warning` |
| Waking → Listening | first audio reaches the engine | none: it already looks like listening | — |
| Listening, any | each meter tick | The bars follow the level smoothed by `VoiceCallLevels` (40 ms attack, 220 ms release). Edge opacity is 0.45 + 0.55 × level | — |
| Heard → settled word | a final result | The lit words crossfade to ink (180 ms) | — |
| Touch-down → held | still down at 280 ms | The hold engages: the capsule lifts to 1.08 and *Release to keep · ‹ slide to cancel* crossfades into the box's status line | `hold` |
| Touch-down → hands-free | lifted before 280 ms | nothing moves: the take opened hands-free and stays so, *0:00 · Tap to stop* already in the box | — |
| Held → Release to cancel | slid ≥ 72 pt left (desktop: 60 px) | The capsule tints danger (180 ms) and the take's words dim | `notch` |
| Held → Release to send | the finger enters Send's frame (+12 pt slop) | Send scales to 1.15 with an accent ring | `notch` |
| Either armed → held | slid back | reverses | `selection` |
| Listening → Settling | tap the capsule, release, the chord again, Send or ⏎ | The bars sink to the floor (160 ms) while the capsule holds its width, then it narrows back to the mic. The edge fades (300 ms) | `listenEnd` |
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

**Mac.** A borderless `mic` control sits left of Send, with a tooltip of *Dictate (⌃⇧D): click to talk, hold to talk while held*. It takes its own mouse down, drag and up: a button's click arrives only on the way up, too late for the first word. Listening, `PromptEditor`'s field wears the lit edge, the ultracode aura parks, and the control becomes the capsule. Holding the button with the mouse and dragging left past 60 px arms cancel, so the gesture is the same as the phone's. The chord ⌃⇧D comes from the shared registry and is rebindable. Esc cancels, and ⏎ stops and sends (respecting send-on-Return). **Chat ▸ Dictate** carries the chord in the menu bar. The hint is a line inside the composer's own glass, above the editor, because glass never stacks on glass.

**Linux.** A chip in the pill row between attach and Send, in the strip's own vocabulary: the `audio-input-microphone-symbolic` glyph and the word *talk*. Listening, the chip fills with the accent and shows five bars drawn in a `GtkDrawingArea` beside the timer. The box wears a lit edge drawn by the aura's own painter in one colour, its glow following the voice; a tick callback reads one number per frame. The hint is a right-aligned line above the box. ⌃⇧D, Esc and ⏎ work as on the Mac. **The first press downloads the model:** a popover from the mic reads *Dictation runs on this computer · Speech model, English · 474 MB, once · NVIDIA Open Model License* with **Download**. While downloading, a bar reads *212 MB of 474 MB · 40 s left* with **Cancel**. After that it reads *Ready. Click, or hold ⌃⇧D, to talk*. There are no toasts and no command to paste. A machine without a microphone gets the button dimmed, with the tooltip *No microphone answers*.

**Quick Ask (Mac and Linux).** The panel's field carries the same control between the box and its round Send, styled as Send's round sibling (on Linux the chip drops its word and its pill), with the hint on a line under the field so the box never moves as the hint comes and goes. The chord is the registry's, read through the panel's own key handling because the panel is not the window the registry serves. While a take is open Esc throws it away instead of putting the panel away, ⏎ (or Send) settles it and asks, and ⌥⏎ / Alt+⏎ keeps what is shown and asks the party. With no transcript, the words it knows are what is on offer from the pasteboard, the aimed machine's commands and the model it would ask. While the question is out the control dims and takes no press; a question that comes back hands it back. A panel put away mid-take keeps what it showed and files it as that machine's draft. On the Mac, **Chat ▸ Dictate** acts on the panel when the panel is the key window.

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

## 13. What building it changed

- **The Linux control is a chip, not an icon button.** The pill row speaks in glyph-and-word chips (*⏎ send*, *■ Stop*), and a round icon would have been the only stranger in it.
- **The Linux hint moved above the box.** In the pill row it was squeezed to nothing beside the place, the dial and the lanes.
- **The iOS hint lives in the screen's view.** The facts chips sit directly above the composer and drew over a hint that was the composer's own subview.
- **Send answers a held take on every desk.** It glows faintly while a take is held and lifts and rings when the take is armed to send. The mocks had it; the first build forgot it.
- **Letting go of any key of the chord ends a hold on Linux.** GTK does not hand the window the letter's release once its press was spent on an action, so the modifiers' release counts too, which is also what *hold ⌃⇧D* means.
- **On iPad the chord toggles.** A hardware key's release is not delivered to the screen once a key command took the press, so hold-to-talk there is the button's.
- **Every request to a take runs in order.** A quick tap's switch to hands-free could reach the take before it had opened and be overwritten by it, leaving a tap behaving like a hold.
- **A not-ready control opens its popover on release.** Opened on press, the popover was closed again by the same click's release.
- **Quick Ask got the microphone after the first ship.** The spec said every prompt composer and the build stopped at the chat and Home; the desktop Quick Ask is the composer people summon from anywhere, so it now carries the control, the chord and a vocabulary built from what is copied.
- **Send settles a take on Linux too.** Send mid-take sent the box as shown, the heard tail included; it now settles the words first, as ⏎ does and as the Mac always did.
- **The real engine was proven end to end** in the Linux harness: the model downloaded (474 MB), passed its SHA-256 check, unpacked to 662 MB, loaded in 1.4 s, and wrote *After early nightfall the yellow lamps would light up here and there the squalid quarter of the brothels* from a recording played as the microphone, first words after 2.1 s from cold.


## 14. Inside the box, motion through every state, and a hold that engages

Asked for on 2026-11-08, after the first builds: *don't put a label above the compose box for the state of the recording, have it be inside it; have the talk button transition smoothly through all states; should a long press do something? do that.*

**What was wrong.** The status sat outside the box it describes, above it on iOS (a floating capsule), on the Mac (a line over the editor) and on Linux (a line over the box), and under the field in Quick Ask, so the eye went from the box to a label and back, and the box's neighbours jumped as the label came and went. The control set most of a face at once: colours, glyphs, the download badge and the ring snapped, and only the capsule's width moved. A long press opened the microphone the same way a tap did and nothing happened at 280 ms, so the hold that already existed could not be felt or seen until the release, and nobody finds a gesture that gives no sign of itself.

**The status is the box's last line.** The words are the ones `DictationReading.hint` and `.ending` already say; only where they stand changes, so no translation moves.

- **iPhone and iPad.** While a take is open, or its ending lingers, the composer takes its stacked shape and the status sits in the accessory's seat in the box's bottom row, just left of the microphone: the model pill and the attach button fade out (0.2 s) as the status fades in, and a one-line composer grows its second row with the same 0.32 s spring the capsule uses. When the line goes, the pill comes back and the box returns to the shape it had. Home's composer does the same.
- **Mac.** The status is a line inside the editor's own bordered field, under the words, set trailing so it ends beside the microphone. The scroll view's bottom moves up by the line's height and the field grows by it, animated with the field's height (0.2 s ease-out), so text never runs under it. Quick Ask's bare field is the same `PromptEditor` and gets it for free. The line that stood over the editor is gone.
- **Linux.** The same line, as an overlay at the bottom end of `PromptEditor`'s overlay, inside the edge that lights; the text view's bottom margin grows by the line's height while it shows, and a revealer slides and fades it in (200 ms). The chat's line above the box and Quick Ask's under the field are gone.
- The placeholder stays the placeholder (*Listening…* while the box is empty); the status line never takes its place, so nothing moves when the first word lands.

**The control moves through every state.** Every property is animated from where it stands to the face's target, never from a reset, so a state that arrives mid-animation bends the motion rather than restarting it:

| Property | Motion |
|---|---|
| Tint (mic glyph, capsule fill, halo, ring) | 180 ms ease-out colour blend; accent → danger when a cancel arms, back when it disarms |
| Width (rest ↔ capsule ↔ hidden) | spring 0.32 s, damping 0.75 (Reduced Motion: 150 ms ease) |
| Glyph (mic ↔ mic.slash, mic ↔ bars) | symbol replace transition on iOS and the Mac, a 150 ms crossfade on Linux (`GtkStack`); the bars rise out of the floor as the glyph fades |
| Download badge | scales 0.6 → 1 and fades in (180 ms); out the same way when the download starts |
| Ring | fades in at 0 as the badge leaves, fills smoothly between readings (250 ms), closes to a full circle, fades out (200 ms), then the mic pulses once |
| Held | the capsule lifts to 1.08 with a stronger halo (spring) the moment the hold engages, and settles back on release |
| Armed to send | the capsule shrinks to 0.86 toward Send, which lifts and rings |
| Settling | the bars sink to the floor (160 ms) while the capsule holds its width; then it narrows back to the glyph |
| An ended take | the rest glyph carries the ending's colour for 0.6 s (accent for kept or sent, danger for discarded, warning for a problem) and fades to secondary ink |
| Hidden ↔ shown (a call) | width to 0 and fade out, 220 ms, and back |

Linux draws the same motion with GTK's own CSS transitions on `color`, `background-color`, `border-color`, `min-width`, `opacity` and `transform` (200 ms ease-out) and a crossfading stack for the glyph and the bars. Reduced Motion everywhere keeps the crossfades and drops the springs, the scales and the pulse.

**What the critique changed.** Three independent reviews read this section against the code before a line of it was built, and these are their findings, decided:

- *One value per motion*: tint 180 ms, width spring 0.32 s at damping 0.75, glyph replace or crossfade 180 ms, held lift 1.08, armed-to-send 0.86, settle sink 160 ms, hide and show 220 ms, ending flash 0.6 s then a 0.3 s fade, status line in and out 0.2 s, its words changing 0.15 s. §3 and §4 cite the same numbers.
- *The phone's status takes the accessory's seat without evicting the pill.* It is its own view beside the pill; the box is stacked while either is present, and the pill and the paperclip fade by opacity, so the model pill keeps its state and its own refresh never fights the line. Home does the same in a short window, growing the row for the length of the take.
- *Plain words, never glass on glass*: the phone's line is text on the box's own glass, in the reader's type size, two lines at most, with Undo reachable over 44 points.
- *The Mac field lets Undo be clicked.* The field sends every press to the text view except a scroller's and a button's. The field's height counts the line, animates with it, and Quick Ask refits when it changes.
- *A line shows only when it has words*: a kept or sent take ends with no line, a download that fails says *The download didn't finish. Try again.* for 4 s as a notice of its own, never as a take that stopped.
- *Undo is offered only until the box is edited*, so it can never write an old take over new words.
- *What the hand did shows before the session says it back*: the engaged hold and the slid arm are laid over the take's snapshot (`DictationSnapshot.pressed`), so the lift, the haptic and the status line land together, and a quick release after a slide cancels or sends rather than reading a stale arm.
- *A press that is lost ends the way a release would*: a tap's take stays open, a hold's ends. The Mac now notices the app or the window letting go mid-press.
- *Auto-repeat of a chord does nothing* after its first press, also on a control that is not ready.
- *Linux keeps the timer in one place*: the chip's word slides away while it listens, so the capsule shows the bars and the box's line shows the time. Send wears a soft ring while a hold is engaged, as on the phone and the Mac.
- *The iPad keyboard chord stays a toggle*: a hardware key's release is not handed to the screen once a key command took it. VoiceOver's double tap toggles too.
- *The live dot breathes without restarting* on every new word or second, the halo is owned by the per-frame level alone, and a quick tap-tap never inherits the last take's edge fade.
- *Linux has no haptics*: the hold is shown by the lift and the line.

**A long press is hold-to-talk, and it engages.** The press still opens the microphone on the way down, so the first word is never lost, but the take opens hands-free. If the press is still down at 280 ms the hold engages: the take becomes held, the capsule lifts, the phone plays a new `hold` cue (a firm, short tap, distinct from `listen`, listed with the others in Settings ▸ Haptics as *Holding to talk*), a Force Touch trackpad gives a level-change tick, and the status line changes to the held words, *Release to keep · ‹ slide to cancel* on a phone and *Release to keep · drag left to cancel* on a desktop, while Send glows as a drop target. Releasing an engaged hold keeps the words (or cancels or sends if a slide armed it); releasing before the hold engaged changes nothing, because the take is already hands-free. A slide arms nothing until the hold has engaged, so a tap's jitter can never arm a cancel. The Mac and Linux chord works the same way: held past 280 ms it engages, and letting go ends the take. `DictationPress` gains `tick(at:)`, which answers `.becomeHeld` once when a press crosses the threshold, and its short release answers nothing. A long press on a control that is not ready opens the same sheet or popover as a click, on release. On Linux the button's own click that follows a pointer press is ignored, so a long press can never toggle a second time.
