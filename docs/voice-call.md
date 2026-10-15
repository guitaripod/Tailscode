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

## Words and faces (Core)

`VoiceCallReading` writes every word; `VoiceCallFace` is the one picture of the call on every desk
(connecting sweeps, listening breathes slowly, hearing is lit steady, speaking breathes with the
voice's level, degraded holds perfectly still in the danger tone, ended holds still). The agent working
is the existing `ActivityKind` face and wins the chat's status line as it does today; the call adds its
own, never replaces it. A client draws; it invents no word.

Availability is read like `DelegateReach`: `VoiceReach` from `GET /health` per server, with the reason
a call cannot start written out (no gateway, the model loading, the GPU busy, a gateway too old).

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
- Core: `VoiceCallSession` against a fake gateway, `SpokenDigest` against transcript fixtures,
  readings and faces as pure functions.
- Linux: the headless harness (`scripts/dev-linuxapp.sh`) with a PulseAudio null sink as the
  microphone, a WAV played into it, and the recorded playback checked.
- iOS and Mac: compile on the Mac; echo cancellation and interruptions are a short manual check on
  the iPhone Air, and that is said plainly rather than implied.
