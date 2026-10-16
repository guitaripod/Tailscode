# Setup

A person should reach a working first conversation, and every later capability, without reading
instructions, transcribing an address, minting a password, or finding out at the moment of use that
something was missing. The machine proves what it can do, the app draws it, and every road into a
feature that is not ready leads to the same checklist.

## Principles

1. **The machine proves, the app draws.** A daemon reports what is true of its machine as checks with
   stable ids and facts; Core writes every word, in the person's language. A check the app can run
   itself (is ComfyUI answering, are its models there) is produced the same way on the client.
2. **Nothing the app can verify is asked of the person.** No password to mint, no port to guess, no
   address to type when a link, a code or a probe can carry it.
3. **No dead end.** A failing check names its one fix: a button for a job the machine can do, or one
   copyable command for the one thing that needs a person with administrator rights. A feature that
   cannot work on a machine says so once, with the reason, and then stays out of the way.
4. **Every road in leads to the same place.** The Call button on a machine without voice, the video
   button on a machine without models, the server screen's capabilities and the first-run flow all
   open the same checklist for the same capability.
5. **Honest hardware.** What a capability needs (an NVIDIA GPU with 80 GB for voice) is stated before
   anything is downloaded, read from the machine, never guessed.
6. **Nothing is installed without being asked, and nothing leaves the tailnet.** Downloads come from
   the vendor's own host to the person's machine; the app never relays them.

## Pairing

The machine prints a link and a QR code when an agent bridge finishes installing, and again on demand
(`claude-bridge pair`, `omp-bridge pair`):

```
tailscode://connect?v=1&host=<tailnet name or address>&port=<port>&agent=<claude|omp|opencode>&name=<machine name>[&key=<password>]
```

`key` is present only when the machine does not trust its tailnet (a password is its only key). The
link only ever prefills: nothing is saved until the person confirms, and a link naming a host that is
not on the tailnet says so before anything is tried.

- iOS: scan the code with the camera (the setup screen has a scanner), or open the link from Messages,
  AirDrop or Notes. The setup screen also offers to send the install command to the person's computer
  through the share sheet.
- Linux and the Mac: paste the link into the setup window, or open it (`tailscode://` is registered).
- The first screen after a link arrives is the checklist with its rows already proven.

`PairingKit` (CodingAgentKit) owns the link's format, the QR encoder and the terminal renderer, so the
bridges and the apps can never disagree.

## The machine checklist

`SetupKit` (CodingAgentKit) is the wire any daemon speaks to offer capabilities:

- `GET /setup` answers `[SetupReport]`, one per capability the daemon owns. A report has `capability`,
  `available` (false when this machine can never do it: no GPU, wrong OS), `ready`, and `checks`.
- A `SetupCheck` has a stable `id`, a `state` (`ok`, `todo`, `working`, `blocked`, `unavailable`),
  `facts` (numbers and names, never sentences), an English `detail` as a fallback for a newer daemon
  than the app, and an optional `fix`.
- A `SetupFix` is `job` (the daemon does it: `id`, label key, bytes and minutes it will take) or
  `command` (one copyable command for what needs the person's privileges, with the reason).
- `POST /setup/fix` starts a job and answers a `SetupJob`; `GET /setup/jobs/{id}` follows it (step,
  fraction, bytes, state, the failure as an id and facts); `DELETE /setup/jobs/{id}` cancels it. Jobs
  survive the client going away and are found again by id, like an update.
- The daemon does the fixes in order and idempotently: running a fix twice is safe, a half-finished
  download resumes.

Core's `SetupReading` turns ids and facts into words; unknown ids fall back to `detail`. One
`SetupChecklist` model per capability (rows, the primary action, the one state that matters) is what
the three clients draw: a row is a glyph (the activity vocabulary: breathing while working, still
when settled), a title, one line of facts, and its fix button.

## Capabilities

| Capability | Owner of the checks | Needs |
| --- | --- | --- |
| Agent (Claude Code, omp, opencode) | the bridge's health and the client | a bridge, the CLI, a sign-in |
| Voice calls | `voice-bridge` | NVIDIA GPU with 80 GB, Docker with CDI, the model (44 GB), the image (22 GB) |
| Image and video | the client (`MediaDoctor`) | ComfyUI reachable, its nodes and model files |
| Delegate | the `delegate` daemon | its own toolchain |
| Preview | `previewd` | its own checklist (the existing doctor) |

The server screen has one Capabilities section: a row per capability that is `available`, with its
state and the checklist behind it. A capability that is `available: false` is not shown, except as a
single quiet line when the person asked for it by tapping its entry.

## Voice on demand

The gateway manages the engine container itself. A call on a machine whose model and image are present
but whose engine is stopped starts the engine (if the GPU has the memory free; the gateway never
stops someone else's job) and says so while it loads, which takes up to five minutes; the engine stops
again after ten idle minutes so the GPU goes back to what else it does. The state is on the wire
(`engine`: `ready`, `loading`, `stopped`, `busy`, `down`, plus progress) so the call face can say
"Starting the voice model" instead of failing.

## Images and video

Before the first render, and whenever the endpoint is saved, the client asks ComfyUI what it has
(`object_info`, its model lists) and compares it with what each lane needs. A missing file is named
by its role and size ("the video model, 42 GB"), never by a node's error. The endpoint defaults to
the agent server's host on 8188 and is found by probe; it is kept with the profile so every device
sees it. Installing ComfyUI and the models is a documented recipe (`docs/media-setup.md`) the checklist
proves row by row; a daemon fix for it arrives with the models being published somewhere a stranger
can download them.

## First run

One screen. If a link or code arrived, the machine is already known and the rows prove themselves.
Otherwise the screen offers, in this order: scan the code from your computer, open a link, and "I
don't have a machine yet", which shows the one install command with a Share button to send it to the
computer and waits for the machine to appear. The demo stays one tap away. Tailscale on this device
is proven first and its absence is the only thing the screen asks the person to go and do.

The install command downloads a prebuilt binary and needs no toolchain; a machine the binary does
not fit builds from source with the old script. When the install finishes it checks `tailscale`, the
agent CLI and its sign-in, prints the pairing link and QR, and says what is left in plain words.

## Testing

- `SetupKit` and `PairingKit`: golden JSON, round trips, QR against known vectors, link parsing
  against hostile input.
- Daemons: fake machines (a fake `docker`, `nvidia-smi`, `ngc` on `PATH`) so every check state and
  every job is exercised without a GPU or a download.
- Core: `SetupReading` for every id in every state, the checklist model, `MediaDoctor` against a mock
  ComfyUI (`scripts/mock-comfyui.py`).
- Clients: the headless Linux harness for the visuals; iOS and Mac are compile-checked, and what only
  a device shows is written down.
