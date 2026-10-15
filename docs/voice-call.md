# Voice call

A call is a voice for a chat that already exists. The person talks, the words go to the agent the
conversation already has, and a short spoken account of what the agent is doing comes back. The model
that listens and speaks (NemotronLabs VoiceChat 11B, on the server's GPU) does none of the building. It
is an ear and a mouth, and everything it says or hears is treated as lossy.

This file is the contract. `VoiceKit` (CodingAgentKit) holds the wire types, `voice-bridge` is the
gateway, TailscodeCore holds the call's words, faces and session, and each client draws it.

## What the model can and cannot do

Facts that shaped the design, from the model card, the paper and NVIDIA's API reference:

- Audio in, audio out. The only thing a client may add to a live session is a `function_call_output`.
  There is no way to make the model speak a given text. Agent words reach the ear only as a tool
  result the model re-voices in its own words.
- While a tool call is outstanding the person cannot interrupt. So every tool answers at once, from
  state the gateway already holds.
- Tool arguments are unreliable (about 42% argument accuracy), so what is sent to the agent is the
  model's own transcript of the person's speech, never the model's arguments.
- The transcript can drop words, the model can run on to talk to itself, and it forgets beyond about two
  minutes of audio. The gateway watches for all three, and a session is disposable: the agent session is
  the source of truth, the voice session carries a persona of a few lines and nothing else.
- English only. Prompts and tool results must be ASCII.
- It needs about 66 GB of VRAM on one GPU and up to five minutes to load.

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
| `phase` | `phase`, `at` | `connecting`, `listening`, `hearing`, `speaking`, `degraded` |
| `user` | `id`, `text`, `final` | what the model heard, for the screen |
| `say` | `text`, `final` | what the model is saying, for captions |
| `dispatch` | `id`, `text` | send this to the agent as the person's prompt |
| `stop` | | cancel the agent's current turn |
| `degraded` | `reason`, `recovering` | `runaway`, `loop`, `engineError`, `engineDown`, `overload` |
| `recycled` | | the voice session was swapped for a fresh one |
| `error` | `code`, `message` | fatal, then the socket closes |

`digest` is ASCII, at most 300 characters. The client builds it (`SpokenDigest`, Core) from the
transcript, and the gateway sanitises it again.

## The model's three tools

All three answer from cached state in well under 50 ms, so barge-in is never lost.

- `send_to_agent`: no meaningful arguments. The gateway sends `dispatch` with every final user
  transcript since the last dispatch, joined, at most 4000 characters, and answers `Sent.` (or
  `Nothing to send.`).
- `agent_status`: answers the last `digest`, or `The agent is idle.`.
- `stop_agent`: sends `stop`, answers `Stopped.`.

If the model skips `send_to_agent`, nothing is sent. That is a measured failure (see the gate), not a
reason to guess: the call's fallback, decided at the gate, is to dispatch every final transcript.

The model cannot start talking by itself. When the agent finishes while the person is silent, the call
chimes and the client plays its haptic; the person asks and `agent_status` answers.

## Watchdogs (gateway)

- **Runaway**: model audio for more than 25 s with no person speaking, or any audio more than 3 s after
  `response.done`. Mute, send `degraded(runaway)`, recycle.
- **Loop**: the same four-word run three times in the last 200 characters of the `say` text. Same.
- **Engine**: a NIM `error`, a closed socket or no event for 10 s while audio is flowing. One recycle,
  then `degraded(engineError)`. NIM unreachable at connect: `error(engineDown)`.
- **Client**: no frame of any kind for 15 s closes the call.
- **Recycle**: the voice session is replaced at a quiet moment after 90 s of audio or 4 turns, whichever
  is first, so the two-minute limit is never met. The client sees `recycled`; nothing else changes.

## Client duties

- Capture the microphone with echo cancellation (the model hears everything the speaker plays, and
  would answer itself), 24 kHz mono PCM16. iOS and Mac use `AVAudioEngine` voice processing; Linux uses
  PulseAudio's simple API (PipeWire speaks it), with the desktop's echo-cancel module or a headset.
- Play the binary frames back with a jitter buffer; stop and flush the buffer when `phase` becomes
  `hearing` (the person is talking over it).
- Keep the screen on and the audio session alive for the length of the call (iOS: playAndRecord,
  voiceChat mode, the audio background mode).
- Show what was heard (`user`) before it is sent: the transcript row is the ordinary pending row.
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

What only a device can show, and has not been shown: whether echo cancellation is good enough that
the voice does not answer itself on the speaker (headphones remain the advice), the first-buffer
latency and the jitter numbers against a real gateway, that the voice processing reconfiguration
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
(connecting sweeps, listening breathes slowly, hearing is lit steady, speaking breathes with the
voice's level, degraded holds perfectly still in the danger tone, ended holds still). The agent working
is the existing `ActivityKind` face and wins the chat's status line as it does today; the call adds its
own, never replaces it. A client draws; it invents no word.

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
`VoiceCallSnapshot`s: face, the last six lines (what the person said, what the voice said, partials
updated in place), when the call started, the degraded reason, whether the line is being redialled,
whether the microphone is muted, whether the agent is busy, and `finishedChimes`, a counter the client
compares with the last one it saw to play the "the agent finished" chime.

- The microphone is asked for first, then the line is dialled, then `hello` goes out. A refused
  microphone ends the call before anything is dialled, with the way back for that platform.
- Capture chunks go out as binary frames, cut to what the gateway accepts. Muted, the call sends
  silence of the same length, so the model hears a quiet room and not a gap.
- Binary frames from the gateway are played, except while the person is speaking (`hearing`) and while
  the voice is degraded. `phase(hearing)` flushes the speaker at once.
- `dispatch` runs the app's send path off the receive loop, one at a time in order, and answers `sent`
  or `refused`. `stop` runs the app's stop. A `degraded` frame flushes the speaker and mutes the voice
  until the next ordinary phase.
- The `agent` frame is debounced 250 ms, sent only when its meaning changed, sent again on every
  `ready`, and repeated every 5 s whether or not it changed.
- A lost line is redialled after 1, 2 and 4 seconds; the third failure ends the call as lost. A `busy`
  error while redialling is the old call not yet released, and counts as a failed attempt. Any other
  `error` frame ends the call with the gateway's reason.
- However the call ends, capture and playback are stopped before the last snapshot is published.
- The chime is raised when the agent goes from busy to not busy while the person is not speaking and
  the voice is not speaking.

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
dispatch, speaking with captions, a status question, one degraded blip in the first loop, a recycle),
a microphone whose level follows the scripted lines and a speaker whose level follows the scripted
speech. `VoiceReachProbe` answers ready for them without asking the network.

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
  the last thing each side said (`VoiceCallLine`: the person in secondary ink, the voice in primary,
  a line still being heard one register quieter, a placeholder where a side has said nothing yet);
  then the agent's digest wearing its `ActivityKind` face. Every line is one line and always present,
  so a live strip has one height for as long as it is live and no frame of a call lays anything out. A phone on its side, which has no height to spare, gets the header alone (face, timer, mute, hang up).
  Ending replaces the strip with the face, `Call ended` and the reason, for six seconds, then clears
  it; never a modal. A microphone that was refused says how to turn it on and offers `Open
  Settings`, and that notice stays twelve seconds because it has something to do.
- **The face** is arithmetic on absolute time from a `CADisplayLink` at the vocabulary's tempo,
  through `VoiceCallFace.intensity(at:level:reduceMotion:)`; the speaking level is the call's output
  level eased by `VoiceCallLevels.smoothed`. It is the activity badge at call size rather than the
  presence orb: the orb draws one aggregate of everything the device watches and has no way to say
  connecting, hearing or speaking-with-a-level without changes to its shader. Hearing, a degraded
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
  `VoiceChime.attention()` with `needsYou`, unless the person or the voice is speaking; connecting
  uses `success`, a degraded voice `warning`, mute `selection`, hang up `tap`. No new cue types.
- **Words**: everything on screen is Core's (`VoiceCallReading`, `VoiceCallFace`, `BetaWords`). The
  one line the app writes for itself is the microphone usage description, localised in all eleven
  languages of `InfoPlist.xcstrings`.
- **Demo**: the `--demo` world's servers are demo hosts, so their chats show the entry, ready, and a
  press runs the scripted call with no network and no audio devices.

What was compiled, on the Mac, for the iOS device SDK with Swift 6 strict concurrency, and what that
proves: the sources type-check against the shared Core. What only the iPhone Air can show, and has not
been shown:

- whether echo cancellation is good enough that the voice does not answer itself on the speaker,
  and how it behaves on the receiver, a wired headset and Bluetooth hands-free;
- route changes in the middle of a call (headset in or out, Bluetooth coming and going), and
  interruptions (a phone call, Siri, another app taking the audio): that the interruption really
  ends the call and the dock says so once;
- the feel of the dock: its height against the keyboard, the composer and the facts row at the
  default and at the largest type sizes; whether the face reads at a glance in sunlight; whether the
  caption lines, which truncate at their head so the newest words stay visible, are readable at
  speed; that the sheen on the beta mark plays once and then stops;
- that the screen stays on and the call survives a locked screen through the audio background mode,
  and that a call the system suspends is ended rather than left half open;
- the microphone prompt on first use and the Settings road after a refusal;
- that the transcript row for a spoken prompt rises and streams the way a typed one does;
- that the chime is audible over the call's route and not over the voice.

## Beta

Calls ship as a beta (`BetaFeature.voiceCall`, see `beta.md`). The sheet lists what is solid and what
is rough, truthfully: English only, headphones recommended, interrupting does not work while the agent
is being asked for status, and what the model heard is shown on screen because it is sometimes wrong.

## The gate

Nothing past the gateway is trusted until the model has been measured on this GPU
(`voice-probe`, a CLI in voice-bridge). Targets, to be calibrated against the first baseline:

- end of speech to first audio, p95 under 700 ms
- silence within 300 ms of a barge-in
- no runaway turn in a 10 minute soak with scripted dialogue and silences
- `send_to_agent` called on at least 95% of 50 scripted task utterances, else the dispatch fallback
- word error rate of the user transcript, gated against the baseline
- a recycle mid-call with no audible gap over 1 s
- sm_120 (RTX PRO 6000 Blackwell) runs the container at all

## Testing

- `VoiceKit` and `voice-bridge`: `swift test`, with a fake NIM that replays scripted event sequences
  (speech, tool calls, runaway, loops, errors, slow tools) and asserts the gateway's frames.
- Against the real gateway: a throwaway package imports TailscodeCore and drives a real `VoiceCallSession` over
  `URLSessionVoiceTransport` against `voice-bridge` and `voice-probe fake-nim` on ephemeral ports (a whole call,
  barge-in, a killed and a restarted gateway, a refused connection, the reach probe and the desk).
- Core: `VoiceCallSession` against a scripted transport, fake audio and a manual clock (every
  behaviour above, reconnects, a refused dispatch, a degraded cycle, a debounced flood), `SpokenDigest`
  against transcript fixtures, readings, faces and levels as pure functions, `VoiceReachProbe` against
  a scripted fetcher, and the demo script driving a session through every face.
- Linux: the headless harness (`scripts/dev-linuxapp.sh`) with a PulseAudio null sink as the
  microphone, a WAV played into it, and the recorded playback checked.
- iOS and Mac: compile on the Mac; echo cancellation and interruptions are a short manual check on
  the iPhone Air, and that is said plainly rather than implied.
