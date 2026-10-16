# Voice call

A call is an ear for a chat that already exists. The person talks, the model listens and writes down
what it hears as it hears it, every finished sentence of at least three words goes to the agent the
conversation already has as an ordinary message, and a chime says when the agent finished. Nothing is
spoken back. The model (NemotronLabs VoiceChat 11B, on the server's GPU) does none of the building and
none of the talking, and what it hears is treated as lossy.

This file is the contract. `VoiceKit` (CodingAgentKit) holds the wire types, `voice-bridge` is the
gateway, TailscodeCore holds the call's words, faces and session, and each client draws it. The
design changed on 2026-10-16, when the model was measured on this GPU (see "The gate"): it is an
excellent ear and a poor mouth, so the call is ear only.

## What the model can and cannot do

Facts that shaped the design. The first group is from the model card, the paper and NVIDIA's API
reference; the second is what the gate measured on this machine, which is what decided the design.

- Audio in, audio out. The only thing a client may add to a live session is a `function_call_output`.
  There is no way to make the model speak a given text.
- The transcript can drop words, and the model forgets beyond about two minutes of audio. A session is
  disposable: the agent session is the source of truth.
- English only. Prompts and tool results must be ASCII.
- It needs a lot of GPU memory and up to five minutes to load (see "The gate" for the figures).
- It hears well: first audio arrives 239 ms after the end of speech (p95), and the user transcript
  streams live and is mostly right.
- It does not call tools reliably: 0 of 5 with the shipped prompt, about 1 of 5 with heavily tuned ones.
- It ignores instructions to be silent or to answer in one word, and improvises assistant chatter
  instead. Prompts cannot fix either.

So the call is ear only. The model listens and transcribes; every final transcript of at least three
words is sent to the agent as an ordinary message; the model's own speech and captions are muted at the
gateway and it has no tools; a chime says when the agent finished. The call strip shows what was heard
(the "you" lines) as it is heard. The client never plays the model's audio, never shows a caption of it
and never reads a phase of speaking, so the echo problem of a speaker feeding a microphone is gone and
no headphone advice is given. Because the agent gets what was heard, a misheard word reaches it as
heard, and a pause can split one request into two messages.

## Topology

```
client (iOS / Mac / Linux)  --ws:4102/call-->  voice-bridge  --ws:9000/v1/realtime-->  NIM (VoiceChat)
        |                                          |
        +-- sends the prompt through the app's own send path, reads the agent's events
```

The app stays the only thing that drives the agent. The gateway never talks to claude-bridge,
omp-bridge or opencode. It asks the client to send (`dispatch`) and the client tells it what the agent
is doing (`agent`). The queue, the pending ink, the marks and the Live Activity all behave as if the
person had typed.

`voice-bridge` listens on loopback and on this machine's tailnet address only (`tailscale ip -4`),
port 4102, never on 0.0.0.0. `VOICE_PASSWORD`, when set, is required as a bearer token.

## Wire (VoiceKit, protocol version 1)

`GET /health` answers `VoiceHealth`: gateway version, protocol version, engine state
(`ready`, `loading`, `down`, `busy`), model name, active calls, and a one-line detail.

`ws://host:4102/call` carries two kinds of frame.

- **Binary**: PCM16 little-endian, mono, 24 kHz, both ways. 80 ms (3840 bytes) preferred, any even
  length up to 16 KB accepted. 24 kHz is what the NIM takes and gives, so the gateway never resamples.
- **Text**: one JSON object with a `t` discriminator.

Client to gateway:

| `t` | fields | meaning |
| --- | --- | --- |
| `hello` | `v`, `client` (`ios`/`mac`/`linux`), `app`, `title?` | first frame |
| `agent` | `busy`, `digest`, `turn` | what the agent is doing, pushed on change (debounced 250 ms) |
| `sent` | `id` | the dispatch with this id was sent to the agent |
| `refused` | `id`, `reason` | it could not be sent |
| `bye` | | orderly end |

Gateway to client:

| `t` | fields | meaning |
| --- | --- | --- |
| `ready` | `v`, `gateway`, `model` | the session is open |
| `phase` | `phase`, `at` | `connecting`, `listening`, `hearing`, `speaking`, `degraded`; the app reads `speaking` as `listening` |
| `user` | `id`, `text`, `final` | what the model heard, for the screen |
| `say` | `text`, `final` | what the model is saying; never sent while the model is muted, ignored by the app |
| `dispatch` | `id`, `text` | send this to the agent as the person's prompt: a final transcript of at least three words |
| `stop` | | cancel the agent's current turn; only the tool experiment sends it |
| `degraded` | `reason`, `recovering` | `runaway`, `loop`, `engineError`, `engineDown`, `overload` |
| `recycled` | | the voice session was swapped for a fresh one |
| `error` | `code`, `message` | fatal, then the socket closes |

`digest` is ASCII, at most 300 characters. The client builds it (`SpokenDigest`, Core) from the
transcript, and the gateway sanitises it again. `busy` and `turn` are what an ear-only call uses; the
digest is the account a speaking model would be handed (see "If the model improves").

## What the gateway sends the agent

`VOICE_DISPATCH=transcripts` and `VOICE_SPEECH=muted` are the gateway's defaults. In that mode no tools
are registered with the model at all, and the gateway sends `dispatch` for each final user transcript
of at least three words, as soon as it is final, with a fresh id. Shorter ones (a cough, "yes") are
dropped. The client answers `sent` or `refused` from the app's own send path, exactly as for a typed
message, and the words appear as the ordinary pending row.

The old tool mode (`VOICE_DISPATCH=tool`, the model calling `send_to_agent`, `agent_status` and
`stop_agent`) and the speaking model (`VOICE_SPEECH=model`) remain in the gateway as experiments only.
Tool arguments were never trusted (about 42% argument accuracy), so even then what went to the agent
was the model's transcript of the person's speech, never its arguments.

The model cannot start talking by itself and does not talk at all. When the agent finishes while the
person is silent, the call chimes and the client plays its haptic.

## Watchdogs (gateway)

- **Runaway** and **loop** watch the model's speech (audio for more than 25 s with no person speaking,
  the same four-word run three times in the `say` text). The model is muted, so they do not run in an
  ear-only call; they belong to the speaking experiment.
- **Engine**: a NIM `error`, a closed socket or no event for 10 s while audio is flowing. One recycle,
  then `degraded(engineError)`. NIM unreachable at connect: `error(engineDown)`.
- **Client**: no frame of any kind for 15 s closes the call.
- **Recycle**: the voice session is replaced at a quiet moment after 90 s of audio or 4 turns, whichever
  is first, so the two-minute limit is never met. The client sees `recycled`; nothing else changes.

## Client duties

- Capture the microphone, 24 kHz mono PCM16. iOS and Mac use `AVAudioEngine` with voice processing;
  Linux uses PulseAudio's simple API (PipeWire speaks it), preferring the desktop's echo-cancel module
  when there is one. Nothing the model says is ever played, so echo is not a hazard of the call; the
  speaker carries only the call's chimes.
- Ignore the gateway's binary frames and its `say` frames, and read a phase of `speaking` as
  `listening` (`VoiceCallSession` does this unless it is built with `modelSpeaks`, which no client does).
- Keep the screen on and the audio session alive for the length of the call (iOS: playAndRecord,
  voiceChat mode, the audio background mode).
- Show what was heard (`user`) as it is heard, partial lines updated in place: the transcript row is the
  ordinary pending row once it is sent.
- Never treat the gateway as the authority on the agent. `dispatch` goes through the app's send path
  (`ChatViewModel.send`, or the desktop equivalent) and the result is `sent` or `refused`.

### Apple audio

`AppleVoiceIO` (TailscodeCore, `Voice/Apple/`, compiled only where AVFoundation exists on iOS or
macOS) is the one implementation of both audio seams for the iPhone and the Mac. It owns a single
`AVAudioEngine` and vends `capture` and `playback` from it, because echo cancellation only works when
the microphone and the speaker go through the same voice processing unit. The toolkit-free half is in
Core and tested everywhere: `VoicePCM` (PCM16 little-endian and Float32, `rms(of:)` on a decibel scale
from -50 dBFS to full scale so speech reads 0.3 to 0.7), `VoiceChunker` (any buffer size re-cut into
exact 3840-byte chunks, remainder kept) and `VoiceJitter`/`VoiceJitterQueue` (prebuffer 120 ms, a
240 ms lookahead handed to the device, the oldest waiting audio dropped past 1500 ms queued or 1 s
waited, back to prebuffering after a run dry).

Wiring, in the order it happens: the microphone permission is asked through
`AVAudioApplication.requestRecordPermission` and a denial throws `VoiceAudioError.microphoneDenied`
before any engine or session work; on iOS the session is set to playAndRecord, voiceChat, Bluetooth
hands-free allowed, speaker by default, and activated; voice processing is switched on before anything
is connected or tapped; the tap's first channel is converted to 24 kHz mono Int16, chunked and
yielded. `flush()` stops, resets and restarts the player node. A configuration change rebuilds the
engine on a fresh instance (at most five times in ten seconds, then `onFailure`). On iOS an
interruption that begins ends capture and calls `onInterruption`, and a route change keeps going.
`stop()` tears the engine, tap and session down and is safe to call twice. The Mac app also needs the
microphone usage description and, sandboxed, the audio-input entitlement.

What is proven: the arithmetic above by `swift test` on Linux and on the Mac; that both platforms
compile under Swift 6 strict concurrency (`swift build` on macOS, `xcodebuild` for the iOS device SDK).

What only a device can show, and has not been shown: that the microphone with voice processing hears
speech well enough for the model, that a chime is not clipped by it, the capture latency against a real
gateway, that the voice processing reconfiguration
settles on both platforms and on a Mac with an unusual microphone format, route changes (headset
plugged in or out, Bluetooth hands-free coming and going, receiver against speaker), interruptions
(a phone call, Siri, another app taking the audio) and that the level meters look right on the face.
No file in `Voice/Apple/` has run as audio yet.

### Linux

`PulseVoiceIO` (`TailscodeLinux/PulseVoiceIO.swift`, behind `HAS_PULSE`, libpulse-simple) is both seams: a
microphone read in 80 ms fragments on its own thread and a speaker held to about 120 ms whose `flush()` drops
what is queued. It prefers an `echo-cancel*` source and sink when `pactl` lists one and says which device it
opened in the app log; `TAILSCODE_VOICE_SOURCE` and `TAILSCODE_VOICE_SINK` name them for a harness. Levels are
`VoicePCM.rms` through `VoiceCallLevels`. A build without libpulse answers `VoiceAudioError.unavailable`.

The call is a state of a conversation, not a window. `VoiceCallRunner` holds the one `VoiceCallDesk` and a
main-loop mirror of what it says; each `ChatPane` owns a `PaneCall`: the entry chip in the controls row beside
attach (hidden for `.noGateway`/`.unknown`, dimmed with the reach's own line for loading, busy, engineDown and
tooOld, a password dialog for `.wantsPassword`) and a `CallStripView` docked directly above the composer while the
call is live. The dictated words go through the pane's own queue-or-send path with its model and effort, every
conversation state the pane receives is fed to the call as `SpokenDigest`, and both chimes play through the call's
speaker. The call ends when the pane closes, the pane holds another chat, or the window closes. The face is
`CallFaceMark`: arithmetic from absolute time off the widget's frame clock, no clock at all for hearing,
degraded and ended, and the strip gives up its chips' words, then the clock, then the beta mark as the pane narrows.

## Words and faces (Core)

`VoiceCallReading` writes every word; `VoiceCallFace` is the one picture of the call on every desk
(connecting sweeps, listening breathes slowly, hearing is lit steady, degraded holds perfectly still in
the danger tone, ended holds still). The `speaking` case, which breathes with a voice's level, is kept
for a model that talks again and is never reached: `VoiceCallSession` reads the gateway's `speaking`
phase as `listening`, so no client shows a "Speaking" state. The agent working is the existing
`ActivityKind` face and wins the chat's status line as it does today; the call adds its own, never
replaces it. A client draws; it invents no word, and it promises no speech: the entry's tooltip says the
chat types what you say.

Availability is read like `DelegateReach`: `VoiceReach` from `GET /health` per server
(`VoiceReachProbe`, URLSession based, two seconds), with the reason a call cannot start written out
(no gateway, the model loading, the GPU busy, a gateway or an app too old, a password wanted, the
machine not answering). A refused connection is "no gateway"; a timeout is "not answering". The
protocol must match exactly, so a gateway older than the app and one newer than it are both `tooOld`
and the line says which side to update. `VoiceEndpoint` finds the gateway from a profile's address
exactly as `DelegateAccess.host(of:)` finds the delegate daemon, and keeps an optional password under
`voice.<host>`.

`VoiceCallFace.read(phase:agentBusy:connection:degraded:)` is the pure mapping: `working` is
`listening` while the agent is busy; a dropped line being redialled reads as `connecting` and the
snapshot's `reconnecting` flag changes the word. A question or an approval waiting for the person is
the agent waiting, not working, so it is not `busy`.

## The session (Core)

`VoiceCallSession` is an actor, never main-actor, and owns one call. A client hands it the endpoint,
the three seams (`VoiceTransport`, `VoiceAudioCapture`, `VoiceAudioPlayback`), the app's own send path
and stop, and a `VoiceClock` (monotonic time and a sleep a test can drive). It publishes latest-wins
`VoiceCallSnapshot`s: face, the last six lines (what the person said, partials updated in place), when
the call started, the degraded reason, whether the line is being redialled,
whether the microphone is muted, whether the agent is busy, and `finishedChimes`, a counter the client
compares with the last one it saw to play the "the agent finished" chime.

- The microphone is asked for first, then the line is dialled, then `hello` goes out. A refused
  microphone ends the call before anything is dialled, with the way back for that platform.
- Capture chunks go out as binary frames, cut to what the gateway accepts. Muted, the call sends
  silence of the same length, so the model hears a quiet room and not a gap.
- Binary frames from the gateway are dropped: the model's voice is never played. `say` frames are
  dropped too and a `speaking` phase is read as `listening`. All three come back only for a session
  built with `modelSpeaks: true`, which the tests use for the old path and no client does; with it,
  frames are played except while the person is speaking or the voice is degraded, and `phase(hearing)`
  flushes the speaker at once.
- `dispatch` runs the app's send path off the receive loop, one at a time in order, and answers `sent`
  or `refused`. `stop` runs the app's stop. A `degraded` frame flushes the speaker and mutes the voice
  until the next ordinary phase.
- The `agent` frame is debounced 250 ms, sent only when its meaning changed, sent again on every
  `ready`, and repeated every 5 s whether or not it changed.
- A lost line is redialled after 1, 2 and 4 seconds; the third failure ends the call as lost. A `busy`
  error while redialling is the old call not yet released, and counts as a failed attempt. Any other
  `error` frame ends the call with the gateway's reason.
- However the call ends, capture and playback are stopped before the last snapshot is published.
- The chime is raised when the agent goes from busy to not busy while the person is not speaking.

`SpokenDigest` writes the `agent` frame by rule. It is English and ASCII, not localised, because it is
a tool result for an English-only model: `Working. <what it is doing>.`, `Waiting for you. <the
question, or what it wants approved>.`, `That failed. <first sentence of why>.`, `Done. <the first
one or two sentences of the last answer after the last prompt>.`, `The agent is idle.`, with code
blocks, tables, headings, markdown, addresses and long paths removed. A prompt sent in the last 20
seconds that the agent has not started on is `Working. Starting on it.`, so the model does not say
"idle" in the moment between sending and starting. `turn` rises whenever the digest or `busy`
changes.

The demo hosts (`VoiceDemo.isDemoHost`) run the same session over `VoiceDemoStage`: a scripted
transport that plays forty seconds of cues in a loop (ready, hearing with growing transcripts, a
dispatch, a second request heard and dispatched, one degraded blip in the first loop, a recycle) and a
microphone whose level follows the scripted lines. The voice never speaks in the script. The agent
working and the chime that says it finished come from the conversation the client already holds, as in
a real call. `VoiceReachProbe` answers ready for them without asking the network.

## The desk (Core)

`VoiceCallDesk` is an actor and never main-actor, made once per process by the client and held above every
surface, as `DelegateDesk` is for the delegate. It holds three things.

- **The reach per server**, cached with `VoiceReachProbe`'s answer. `reach(for:)` reads it, `refresh(_:)`
  asks again, `watchReach(of:)` and `unwatchReach(of:)` keep it fresh every 20 s while a surface shows the
  call button, and `reachChanges()` is a stream of each change. The gateway's password is kept per server
  (`remember(password:for:)`), and the probe and the call both send it.
- **The one call.** `start(chat:title:endpoint:client:app:audio:send:stopTurn:)` ends whichever call is
  running (the earlier surface reads `VoiceCallEnd.replaced` on its snapshots), refuses before opening
  anything when the server is not `ready` (the reach's own line), when a password is wanted
  (`VoiceCallStartError.wantsPassword`) or when the audio stack cannot be built, and hands a demo host the
  scripted call with no probe, password or audio factory. `active` is the `ActiveCall`, whose `snapshots`
  is a subscription of its own starting from the latest snapshot, so any number of surfaces can draw it and
  a late one still reads how it ended. `activeChanges()` says when the call changes, `isActive(chat:)` and
  `hangUp()` do what they say, and `feed(agent:chat:)` forwards the agent's account only to the call's chat.
- **The report.** `reportLines(for:)` is `VoiceCallReport` with the cached reach and how the last call on
  that server ended.

A gateway holds one call and keeps reading `busy` for a moment after the hang up of the call this device
made, so the desk accepts `busy` as its own when it holds, or just ended, a call on that server, ends the
earlier call first and waits (3 s at most, polling the health) for the release before dialling.

`TAILSCODE_VOICE_ENDPOINT`, a `ws://` or `http://` address, replaces the endpoint `VoiceEndpoint` finds from
a profile, for development and for the end-to-end check against a real gateway. It is read in
`VoiceEndpoint.override(in:)` and nowhere else, and a demo host is never redirected.

`VoiceChime.finished()` and `VoiceChime.attention()` are the call's two sounds as PCM16 mono 24 kHz (two soft
notes a fifth apart, about 420 ms; one lower, softer note, about 250 ms), pure and platform-free. A client
plays them through the call's own `VoiceAudioPlayback.play(_:)` so they follow its route and echo cancelling:
`finished` when `finishedChimes` rises, `attention` when its own conversation says a question or an approval
is waiting, which the snapshot does not carry, so the choice stays with the client.

## iOS

The call is a state of a conversation on the phone, not a screen. Nothing is pushed or presented
for it; the chat the person is already in grows a strip, and the transcript above it stays fully
visible, so the person watches the agent work while talking.

- **The entry** is one bar button on the chat's navigation bar, beside the overflow menu
  (`ChatCallController.barItem`, `VoiceCallEntryPoint`'s symbol and words). It is not drawn while the
  reach is unknown, being checked for the first time, or `.noGateway`, so a server without a gateway
  never shows a call control. For loading, busy, engine down and too old it is drawn dimmed and still
  takes a press, which answers with the reach's own reason as a toast; a plain disabled bar item
  would have kept that reason from anyone who is not using VoiceOver. A gateway that asks for a
  password opens a prompt, keeps the answer through `VoiceCallDesk.remember(password:for:)` and starts
  the call if that was the only thing missing. While this chat's call is up the button is not drawn:
  the dock is where it is acted on.
- **The dock** (`CallDockView`) is the last arranged view of the stack that floats over the composer
  (`composerAccessories`), below the facts row, so it is directly above the composer and the
  transcript's bottom inset follows it the way it follows a chip. It holds the call's face
  (`CallFaceView`) with its word and a tabular `m:ss` timer, the beta mark, mute and hang up; then
  the last thing the person said as it was heard (`VoiceCallLine`: secondary ink, a line still being
  heard one register quieter, a placeholder before anything is heard); then the agent's digest wearing
  its `ActivityKind` face. There is no line for the voice, because it never speaks. Every line is one
  line and always present, so a live strip has one height for as long as it is live and no frame of a
  call lays anything out. A phone on its side, which has no height to spare, gets the header alone
  (face, timer, mute, hang up).
  Ending replaces the strip with the face, `Call ended` and the reason, for six seconds, then clears
  it; never a modal. A microphone that was refused says how to turn it on and offers `Open
  Settings`, and that notice stays twelve seconds because it has something to do.
- **The face** is arithmetic on absolute time from a `CADisplayLink` at the vocabulary's tempo,
  through `VoiceCallFace.intensity(at:level:reduceMotion:)`; the level a speaking face would lean on is
  the call's output level eased by `VoiceCallLevels.smoothed`, and stays unused while no voice
  speaks. It is the activity badge at call size rather than the presence orb: the orb draws one
  aggregate of everything the device watches and has no way to say connecting or hearing without
  changes to its shader. Hearing, a degraded
  voice and an ended call hold perfectly still and run no clock, and so does everything under Reduce
  Motion. The one clock that keeps running in a still face is the dock's timer, once a second.
- **Plumbing** is `VoiceCallGate`, one per process beside `DelegateGate`, owning the single
  `VoiceCallDesk`. It mirrors reaches and report lines into values the main thread reads without
  waiting on an actor, keeps the screen awake for as long as any call is up and lets go on every end
  path, hangs the call up when the app leaves the front without the `audio` background mode declared
  (the app declares it, so a call survives a locked screen) and when the app terminates, and hangs
  it up when the chat it belongs to is left. A chat on a server with a gateway asks the desk to keep
  its reach fresh while it is on screen. `AppleVoiceIO.onInterruption` and `onFailure` hang up.
- **The agent's account** is computed on every state the view model emits and on every change to what
  the device is holding, with `SpokenDigest.snapshot(from:sending:after:now:)`: the same account as
  the shared digest, except that a prompt this phone has handed over and the server has not echoed
  yet reads `Working. Starting on it.` (a question or an approval still outranks it). Without that,
  the model asked for status straight after `Sent.` would say the agent was idle.
- **A dispatch** goes through `ChatViewModel.send` with the chat's current model and effort, so the
  words appear as the ordinary pending row and are queued, marked and carried by the Live Activity
  exactly as typed words are, and the composer's draft is left alone. `stop` is the ordinary Stop
  (`ChatViewModel.abort`). A blank transcript is the one thing refused.
- **Sounds and cues**: `finishedChimes` rising plays `VoiceChime.finished()` through the call's own
  playback with the `received` cue; a question or an approval starting to wait plays
  `VoiceChime.attention()` with `needsYou`, unless the person is speaking; connecting
  uses `success`, a degraded voice `warning`, mute `selection`, hang up `tap`. No new cue types.
- **Words**: everything on screen is Core's (`VoiceCallReading`, `VoiceCallFace`, `BetaWords`). The
  one line the app writes for itself is the microphone usage description, localised in all eleven
  languages of `InfoPlist.xcstrings`.
- **Demo**: the `--demo` world's servers are demo hosts, so their chats show the entry, ready, and a
  press runs the scripted call with no network and no audio devices.

What was compiled, on the Mac, for the iOS device SDK with Swift 6 strict concurrency, and what that
proves: the sources type-check against the shared Core. What only the iPhone Air can show, and has not
been shown:

- how the microphone behaves with voice processing on the receiver, a wired headset and Bluetooth
  hands-free, and that a chime on those routes is neither clipped nor heard back by the model;
- route changes in the middle of a call (headset in or out, Bluetooth coming and going), and
  interruptions (a phone call, Siri, another app taking the audio): that the interruption really
  ends the call and the dock says so once;
- the feel of the dock: its height against the keyboard, the composer and the facts row at the
  default and at the largest type sizes; whether the face reads at a glance in sunlight; whether the
  caption line, which truncates at its head so the newest words stay visible, is readable at speed;
  that the sheen on the beta mark plays once and then stops;
- that the screen stays on and the call survives a locked screen through the audio background mode,
  and that a call the system suspends is ended rather than left half open;
- the microphone prompt on first use and the Settings road after a refusal;
- that the transcript row for a spoken prompt rises and streams the way a typed one does;
- that the chime is audible over the call's route.

## macOS

The call is a state of a conversation on the Mac too, and a conversation on the Mac is a pane. Nothing
is opened for it: no window, no sheet, no panel. The pane the person is in grows a strip, the transcript
above it stays fully visible, and with several panes tiled each pane can be on its own call (one at a
time per process) while the others keep streaming.

- **The entry** is one chip in the composer's controls row (`PillsRow.callChip`, a `SymbolChip` with
  `VoiceCallEntryPoint.symbol`), between the lane control and the attach button. The row is where
  `docs/chat-design.md` keeps what a person can choose for the next thing they say (model and effort,
  lane, attach, commands), and it is per pane, so a tiled window has one entry per conversation and the
  strip it starts is in the pane it was pressed in. The window's toolbar acts on the focused pane, so
  it would have put the control one pointer-move away from the strip it controls and made it change
  meaning with focus. The chip is not drawn while the reach is unknown, being checked for the first
  time, or `.noGateway`; for loading, busy, engine down and too old it is drawn dimmed and still takes a
  press, which answers with the reach's own reason as a toast; a gateway that asks for a password opens
  a sheet on the window (`NSAlert` with a secure field, the way the dispatcher's password is asked),
  keeps the answer through `VoiceCallDesk.remember(password:for:)` and starts the call if that was the
  only thing missing. While the pane's call is up the chip is not drawn: the strip is where it is acted
  on. The row drops the lane control first and the call chip after the command pill, so a narrow pane
  keeps it.
- **The strip** (`CallStripView`) is one glass shape in the pane's glass group, between the status band
  and the composer capsule, so the transcript's bottom inset follows it exactly as it follows the band
  and a call never covers a line of the conversation. It holds the face (`CallFaceView`) with its word
  and a tabular `m:ss` timer, the beta mark (`BetaBadge(feature: .voiceCall)`, its card opening upward),
  mute and hang up; then the last thing the person said as it was heard (`VoiceCallLine`: secondary
  ink, a line still being heard one register quieter and followed by an ellipsis so the difference is
  also a shape, a placeholder before anything is heard); then the agent's digest wearing its
  `ActivityKind` face. There is no line for the voice, because it never speaks. Every line is one line
  and always present, so a live strip has one height for as long as it is live and no frame of a call
  lays anything out. Mute is a real toggle (the
  slashed microphone, the accent fill, `Unmute` as its name and `Microphone muted` as its value); hang
  up is the danger fill with its word. Ending replaces the strip with the face, `Call ended` and the
  reason, for six seconds, then clears it; never a modal. A refused microphone says how to turn it on
  (`VoiceCallReading.microphoneDenied(client: .mac)`, System Settings under Privacy & Security,
  Microphone), offers `Open System Settings` (the Privacy_Microphone pane) and stays twelve seconds. A
  second call started anywhere ends the first and the first pane's strip says why (`.replaced`).
- **The face** is the activity badge at call size on an opaque disc, not the presence orb (the orb draws
  one aggregate of everything the device watches and could not say connecting or hearing without
  shader changes). Connecting turns, and listening and the agent working
  breathe, on the render server's clock like every other badge in the window; the kept `speaking` face
  is the one whose light would depend on a value that changes every frame, the voice's output level, so
  it alone runs the display's clock (`NSView.displayLink(target:selector:)`, at the vocabulary's tempo),
  and it is never reached while the call is ear only: each frame is
  `VoiceCallFace.intensity(at:level:)` over the level eased by `VoiceCallLevels.smoothed`, laid on the
  badge's alpha and on the disc's `sublayerTransform` about its centre. Hearing, a degraded voice and an
  ended call hold perfectly still and run no clock, and so does everything under Reduce Motion or a
  governor level that allows no pulses. The one clock a still face keeps is the timer, once a second.
- **Plumbing** is `MacVoiceCallGate`, one per process beside `MacDelegateGate`, owning the single
  `VoiceCallDesk`, mirroring reaches and report lines into values the main thread reads without waiting
  on an actor, and holding the Mac awake (`ProcessInfo.beginActivity(.userInitiated)`: no idle system
  sleep and no App Nap, the screen may still sleep) for as long as a call is up, letting go on every end
  path. It hangs the call up when the Mac is going to sleep and when the app quits. `PaneCallController`
  is everything one pane does about a call (the strip, the entry's state, starting, following the
  snapshots, the agent's account, the chimes) and the pane supplies the conversation, the send path,
  the stop, a window for the password sheet and the announcement. The endpoint is
  `VoiceEndpoint(profileURL:)` of the pane's profile; a pane that is live asks the desk to keep that
  server's reach fresh (`watchReach`/`unwatchReach`).
- **The agent's account** is computed on every state the pane applies and on every change to what the
  device is holding, with `SpokenDigest.snapshot(from:sending:after:now:)` where `sending` is
  `PendingSendLedger.hasInFlight`, so a prompt this Mac has handed over and the server has not echoed
  reads `Working. Starting on it.`
- **A dispatch** goes through the pane's `sendPrompt` with the model and effort the composer would send
  with (`ComposerView.promptChoice`): the words appear as the ordinary pending row, are queued while a
  turn runs, marked and carried exactly as typed words are, and the composer's draft is left alone. A
  waiting message that is being rewritten is not touched by a spoken one (`spoken: true` skips the
  replace). `stop` is the ordinary stop (`cancelCurrentTurn`). A blank transcript is the one thing
  refused.
- **Lifetime.** The call lives exactly as long as the pane's hold on its conversation (see
  `docs/tiling.md` 8.9.2): the pane closing, being parked by the governor or a hidden window, another
  chat being opened into it, a page or a stream taking it over, the app quitting and the Mac sleeping all
  hang it up, and a hang up stops capture and playback before the last snapshot is published. The call
  belongs to the pane that started it. A covered or minimised window parks every pane, so a call does
  not survive a window nobody can see.
- **Sounds and cues**: `finishedChimes` rising plays `VoiceChime.finished()` through the call's own
  playback with the `received` cue; a question or an approval starting to wait plays
  `VoiceChime.attention()` with `needsYou`, unless the person is speaking; connecting uses
  `success`, a degraded voice `warning`, mute `selection`, hang up `tap`. Every arrival that is news is
  also announced to VoiceOver.
- **Audio** is `AppleVoiceIO`, the same implementation as the phone, built per call. The direct build is
  unsandboxed and signed without the hardened runtime, so it needs only
  `NSMicrophoneUsageDescription` (in the `MacApp` template, localised in eleven languages through
  `Resources/InfoPlist.xcstrings`, which the Mac targets now include); the App Store build is sandboxed
  and hardened and carries `com.apple.security.device.audio-input` as well.
- **Demo**: the `--demo` world's servers are demo hosts, so their chats show the entry, ready, and a
  press runs the scripted call with no network and no audio devices (the desk hands a demo endpoint the
  scripted stage and never builds `AppleVoiceIO`).
- **Words**: everything on screen is Core's (`VoiceCallReading`, `VoiceCallFace`, `BetaWords`). The only
  line the app writes for itself is the microphone usage description; `Open System Settings`, `Password`,
  `Save` and `Cancel` were already in the catalog.

What was compiled: both Mac schemes, `TailscodeMac` (direct) and `TailscodeMacStore` (`TAILSCODE_MAS`),
on the Mac host, Swift 6 strict concurrency, warnings counted as failures in the files this change
touched. Nothing was launched. No window, pane, popover or strip was ever drawn, and no microphone was
opened. What that proves: the sources type-check against the shared Core and the Info.plist and
entitlements are the ones declared. What only a real Mac can show, and has not been shown:

- how the microphone behaves with voice processing (`AppleVoiceIO`) on the built-in microphone,
  headphones, a wired headset, AirPods and an external USB microphone, and that a chime is neither
  clipped nor heard back by the model; whether the voice processing unit ducks other audio on the Mac
  the way it does on the phone;
- the first microphone prompt in each build (direct and App Store), that the usage text appears in the
  language of the system, and that after a refusal the `Open System Settings` button lands on the
  Microphone pane and the next call works once it is turned on without a relaunch;
- route changes in the middle of a call (headphones plugged in or out, Bluetooth connecting, the default
  input changed in System Settings, a display's speakers coming and going over HDMI): that the engine
  rebuilds, that the call survives, and that five failures in ten seconds really ends it with a notice;
- the feel of the strip: its height against the composer and the status band at the default type size
  and at both ends of the scale, whether the caption line (which truncates at its head so the newest
  words stay visible) reads at the speed of speech, the glass-on-glass look of the strip beside the band and the
  composer capsule, whether the face reads at a glance, that the hang up chip's danger fill passes
  contrast on the glass in light and dark and under the themes, and that the strip's arrival does not
  move a transcript that is being read;
- that the beta mark's hover card opens upward from the strip, stays while the pointer travels from the
  mark onto the card, leaves when it is on neither, and opens from the keyboard (Space, Return) and
  from VoiceOver, and that the single pass of light plays once and stops;
- the tiling behaviour: that a call survives a divider drag, a split and a focus change of its own
  pane, that it really ends in the pane that is parked by the governor under load, in a zoomed-away pane,
  when the window is covered or minimised, and when the chat is switched; that the starter's strip is
  the only one drawn when two panes show the same chat;
- that the Mac stays awake through a long call with the screen asleep, and that a call is ended rather
  than left half open by sleep;
- that the transcript row for a spoken prompt rises and streams the way a typed one does, and that the
  chime is audible over the call's route.

## Setting up, and the engine starting

A server with no gateway, a gateway that says it needs setting up and an engine that is down are not
reasons to toast: `VoiceCallEntryPoint.pressOpensSetup(reach:)` is true for `noGateway`, `needsSetup`
and `engineDown`, the control stays live for them, and the press opens the voice checklist of
`docs/setup.md` on every client (a call that fails to start with one of those reaches opens it too).
Finishing the checklist starts the call. `VoiceCallReading.reason(for:)` no longer tells anyone to run
a service command; it says voice is not set up here and that Call is where to start.

While the gateway loads its model the call face stays `connecting` (it sweeps) and says what is
happening: `VoiceServerMessage.engine` sets `VoiceCallSnapshot.engine` and `engineProgress`,
`isStartingEngine` is true for `loading` and `stopped` before the line opens, and `word` reads
"Starting the voice model" with the percentage when the gateway reports one. The line opening
(`ready`) ends the wait.

## Beta

Calls ship as a beta (`BetaFeature.voiceCall`, see `beta.md`). The sheet says what the call is, in
sentences that match this file: it listens and types what you say into the chat as you speak; it does not
talk back, on purpose, because the model that listens is not good enough at talking; what it heard is
shown as it arrives and is sometimes wrong, so the agent gets what was heard; nothing leaves the
tailnet. Its rough lines are the mishearing, a pause splitting one request into two messages, no voice
answers and no stopping the agent by voice, English only, and the GPU it needs. That last figure comes
from `VoiceRequirements.gpuMemoryMB`, the same constant the setup checklist quotes.

## The gate

Nothing past the gateway was trusted until the model had been measured on this GPU (`voice-probe`, a
CLI in voice-bridge; the raw files of the 2026-10-16 run are `probe.json`, `e2e.json` and `nimexp.py`).
The gate changed the product: the model is an excellent ear and a poor mouth.

| What was measured | Result | Verdict |
| --- | --- | --- |
| End of speech to first audio (the ear's side of the latency, 5 scripted task utterances) | p50 157 ms, p95 239 ms; three end-to-end calls through the gateway 239, 237 and 324 ms | Excellent; the target was p95 under 700 ms |
| User transcript | Streams live word by word every 150 to 300 ms and finalises at the end of speech; 3 words wrong in 49 | Mostly right, not trusted: "cache" heard as "cash", "build" as "bill", a leading "add" dropped |
| Gateway to NIM protocol | Works end to end: session, audio both ways, transcripts, no model errors, no runaway, no recycle in the run | Good |
| Tool calls (`send_to_agent`) | 0 of 5 with the shipped prompt; about 1 of 5 with heavily tuned prompts and argument variants (`nimexp.py`); the end-to-end call through the gateway sent no dispatch | Failed; the target was 95%. Prompts cannot fix it |
| Obeying "be silent" or "answer in one word" | Ignored every time; the model improvises assistant chatter ("I can run those tests for you. Just let me know what specific tests...") that answers nothing | Failed. Prompts cannot fix it |
| GPU memory | The NIM runs two engines in one container, each reserving a share of the whole card: NVIDIA's defaults are 0.45 and 0.40, so 85% of it, and on the 96 GB card with a desktop holding about 12 GB it failed to start. With the gateway's lowered shares (0.30 and 0.25) it loads in about 5 minutes and the container uses about 58 GB, so about 62 GB must be free to start | A card under 64 GB cannot run it. It was documented as 66 GB and 80 GB before the measure |
| sm_120 (RTX PRO 6000 Blackwell) | Runs the container | Pass |

Why prompts cannot fix it: the variants run through `nimexp.py` (the tool's description, an optional
`task` argument, dropping `stop_agent`, longer settle times) moved the tool rate from 0 to about one in
five and never made it reliable, and nothing moved the chatter. What the model does reliably is hear, so
the design uses only that.

The memory finding, for anyone reproducing it. The two shares are plain environment variables the NIM
container reads, `LLM_GPU_MEM_UTIL` (language engine) and `TTS_GPU_MEM_UTIL` (speech engine). The gateway
starts the engine with 0.30 and 0.25 and lets a machine with more room raise them through its own
`VOICE_LLM_MEM_UTIL` and `VOICE_TTS_MEM_UTIL` (0.1 to 0.6; anything else is ignored); lower shares than
that pair have not been tried. The gateway's `voice.vram` is `unavailable` below 64000 MB and
`voice.engine` is `busy` while less than 62000 MB is free (`needMB` on both). Core quotes the same
figures before it has heard from a machine, as `VoiceRequirements.gpuMemoryMB` (the card) and
`engineMemoryMB` (the free memory), in the unit its size formatter uses, so the card reads 64 GB and
the free memory 62 GB; the machine's own `needMB` wins where it is present.

Targets of the original gate that no longer apply: silence within 300 ms of a barge-in, no runaway
turn in a 10 minute soak, and a recycle mid-call with no audible gap, all of which concern a voice.

## If the model improves

Re-enable in this order, and only after the gate passes on the new model:

1. Run the gate again: `voice-probe run --wav u1.wav --wav u2.wav --instructions prompt.txt
   --summary-table` against the new engine (`--tools-json` registers the tools in a file, `--no-tools`
   registers none, `--barge-in-ms` and `--soak-seconds` measure the interruption and the soak). The bar
   is the original targets: tool calls on at least 95% of 50 scripted task utterances, a model that
   stays quiet when told to, first audio p95 under 700 ms, no runaway in a 10 minute soak, silence
   within 300 ms of a barge-in.
2. Tools: set `VOICE_DISPATCH=tool` on the gateway. The model's `send_to_agent`, `agent_status` and
   `stop_agent` answer from cached state in under 50 ms, so barge-in is never lost. Nothing in the
   client changes: `dispatch`, `stop` and the `agent` digest (`SpokenDigest`) are still on the wire and
   still handled.
3. Speech: set `VOICE_SPEECH=model` on the gateway, build `VoiceCallSession` with `modelSpeaks: true`
   in `VoiceCallDesk`, and bring back what was removed from the three strips: the line for the voice
   (`VoiceCallLine.Kind.voice` is still produced by the session) in `CallDockView`, `CallStripView`
   (Linux) and `CallStripView` (Mac), `VoiceCallReading.voiceLabel` and `voicePlaceholder`, a
   headphone hint, the speaking level on the face (`speaking` is kept in `VoiceCallFace` and both
   face views), the demo script's speaking windows, and the card's "does not talk back" paragraph.
4. The runaway and loop watchdogs apply again, and the beta card, this file, `docs/setup.md` and the
   call bullet in `CLAUDE.md` must change in the same commit.

## Testing

- `VoiceKit` and `voice-bridge`: `swift test`, with a fake NIM that replays scripted event sequences
  (speech, transcripts, tool calls, runaway, loops, errors, slow tools) and asserts the gateway's frames.
- Against the real gateway: a throwaway package imports TailscodeCore and drives a real `VoiceCallSession` over
  `URLSessionVoiceTransport` against `voice-bridge` and `voice-probe fake-nim` on ephemeral ports (a whole call,
  barge-in, a killed and a restarted gateway, a refused connection, the reach probe and the desk).
- Core: `VoiceCallSession` against a scripted transport, fake audio and a manual clock (every
  behaviour above, reconnects, a refused dispatch, a degraded cycle, a debounced flood, and that an
  ear-only call plays nothing of the model and never reads `speaking`), `SpokenDigest` against transcript
  fixtures, readings, faces and levels as pure functions, `VoiceReachProbe` against a scripted fetcher,
  and the demo script driving a session through every face a listening call has, both dispatches and
  the chime.
- Linux: the headless harness (`scripts/dev-linuxapp.sh`) with a PulseAudio null sink as the
  microphone, a WAV played into it, and the recorded playback checked.
- iOS and Mac: compile on the Mac; interruptions, route changes and the chime are a short manual check
  on the iPhone Air, and that is said plainly rather than implied.
